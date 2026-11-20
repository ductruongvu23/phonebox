#import "PBUsbListener.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

const int PBUsbClientPort = 8765;
const int PBUsbPoolPort = 8767;
static const NSUInteger kMaxIdle = 16;

/// Listening socket on 127.0.0.1:port, non-blocking; -1 when the port is taken.
static int PBListen(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_len = sizeof a; a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0 || listen(fd, 16) != 0) { close(fd); return -1; }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    return fd;
}

static void PBPrepare(int fd, BOOL blocking) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, blocking ? (fl & ~O_NONBLOCK) : (fl | O_NONBLOCK)); // accepted sockets inherit O_NONBLOCK on BSD
}

static BOOL PBWriteAll(int fd, const uint8_t *p, ssize_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, (size_t)n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return NO;
        p += w; n -= w;
    }
    return YES;
}

/// Copies both ways until each side has ended, then closes both. The half-close travels along: when one side ends, the
/// other gets a FIN, so the PC (whose WhenAny pipe ends on the first EOF) sees the end of a request promptly.
static void PBSplice(int a, int b) {
    dispatch_group_t g = dispatch_group_create();
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    void (^pump)(int, int) = ^(int from, int to) {
        uint8_t buf[16384];
        for (;;) {
            ssize_t n = read(from, buf, sizeof buf);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0 || !PBWriteAll(to, buf, n)) break;
        }
        shutdown(to, SHUT_WR);
        shutdown(from, SHUT_RD);
    };
    dispatch_group_async(g, q, ^{ pump(a, b); });
    dispatch_group_async(g, q, ^{ pump(b, a); });
    dispatch_group_notify(g, q, ^{ close(a); close(b); });
}

@interface PBPoolConn : NSObject
@property (nonatomic) int fd;
@property (nonatomic, strong) dispatch_source_t source;
@property (nonatomic) BOOL handedOver;
@end
@implementation PBPoolConn
@end

@implementation PBUsbListener {
    dispatch_queue_t _q;
    BOOL _started;
    int _poolFD, _clientFD;
    dispatch_source_t _poolSrc, _clientSrc;
    NSMutableArray<PBPoolConn *> *_idle;
}

+ (instancetype)shared {
    static PBUsbListener *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PBUsbListener new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("phonebox.usb", DISPATCH_QUEUE_SERIAL);
        _poolFD = _clientFD = -1;
        _idle = [NSMutableArray array];
    }
    return self;
}

- (void)start {
    dispatch_async(_q, ^{
        if (self->_started) return;
        self->_started = YES;
        int fd = PBListen(PBUsbPoolPort);
        if (fd < 0) return; // phoneboxd (or another copy) already owns the tunnel
        self->_poolFD = fd;
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, self->_q);
        dispatch_source_set_event_handler(src, ^{ [self acceptPool]; });
        dispatch_source_set_cancel_handler(src, ^{ close(fd); });
        self->_poolSrc = src;
        dispatch_resume(src);
    });
}

- (void)stop {
    dispatch_async(_q, ^{
        if (!self->_started) return;
        self->_started = NO;
        if (self->_poolSrc) { dispatch_source_cancel(self->_poolSrc); self->_poolSrc = nil; self->_poolFD = -1; }
        [self closeClientListener];
        for (PBPoolConn *c in [self->_idle copy]) [self drop:c];
    });
}

#pragma mark Idle connections from the PC (queue _q)

- (void)acceptPool {
    for (;;) {
        int fd = accept(_poolFD, NULL, NULL);
        if (fd < 0) break;
        PBPrepare(fd, NO);
        PBPoolConn *c = [PBPoolConn new];
        c.fd = fd;
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _q);
        __weak PBPoolConn *wc = c;
        dispatch_source_set_event_handler(src, ^{
            // an idle connection is silent: readable means the PC closed it (or sent something it should not have)
            PBPoolConn *cc = wc;
            if (!cc || cc.handedOver) return;
            [self drop:cc];
        });
        dispatch_source_set_cancel_handler(src, ^{ if (!c.handedOver) close(fd); });
        c.source = src;
        [_idle addObject:c];
        dispatch_resume(src);
        while (_idle.count > kMaxIdle) [self drop:_idle.firstObject];
    }
    [self syncClientListener];
}

- (void)drop:(PBPoolConn *)c {
    [_idle removeObject:c];
    if (c.source) { dispatch_source_cancel(c.source); c.source = nil; }
    [self syncClientListener];
}

#pragma mark 127.0.0.1:8765, open only while the PC has a tunnel ready

- (void)syncClientListener {
    if (_idle.count > 0 && _clientFD < 0 && _started) {
        int fd = PBListen(PBUsbClientPort);
        if (fd < 0) return;
        _clientFD = fd;
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _q);
        dispatch_source_set_event_handler(src, ^{ [self acceptClients]; });
        dispatch_source_set_cancel_handler(src, ^{ close(fd); });
        _clientSrc = src;
        dispatch_resume(src);
    } else if (_idle.count == 0 && _clientFD >= 0) {
        [self closeClientListener];
    }
}

- (void)closeClientListener {
    if (_clientSrc) { dispatch_source_cancel(_clientSrc); _clientSrc = nil; }
    _clientFD = -1;
}

- (void)acceptClients {
    for (;;) {
        if (_clientFD < 0) return;
        int client = accept(_clientFD, NULL, NULL);
        if (client < 0) break;
        PBPoolConn *tunnel = _idle.lastObject; // the freshest: the least likely to be stale
        if (!tunnel) { close(client); continue; }
        tunnel.handedOver = YES;
        int tfd = tunnel.fd;
        [_idle removeObject:tunnel];
        if (tunnel.source) { dispatch_source_cancel(tunnel.source); tunnel.source = nil; }
        PBPrepare(client, YES);
        PBPrepare(tfd, YES);
        PBSplice(client, tfd);
    }
    [self syncClientListener];
}

@end
