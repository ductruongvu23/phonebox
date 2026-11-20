// phoneboxd: keeps the USB tunnel up while the app is closed, and takes commands from the PC.
//
//   127.0.0.1:8767  idle connections from the PC (PBUsbListener)      -> 127.0.0.1:8765 for the app
//   127.0.0.1:8768  control: "wake", "sleep", "open", "status" + "\n" -> one-line answer
//
// Both ports are loopback only; usbmuxd arrives from loopback, so only a cable (or a process on the phone) reaches them.
// The commands become Darwin notifications that the SpringBoard tweak (PhoneBoxSB) carries out in-process, where the
// screen and app launching live. Without the tweak the notifications go nowhere and the tunnel still works.
#import <Foundation/Foundation.h>
#import <notify.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import "PBUsbListener.h"
#import "PBFlags.h"

static const int kControlPort = 8768;
NSString *const PBCmdWake = @"com.ductruongvu23.phonebox.cmd.wake";
NSString *const PBCmdSleep = @"com.ductruongvu23.phonebox.cmd.sleep";
NSString *const PBCmdOpen = @"com.ductruongvu23.phonebox.cmd.open";

static NSString *PBRun(NSString *cmd) {
    if ([cmd isEqualToString:@"wake"]) { notify_post(PBCmdWake.UTF8String); return @"ok"; }
    if ([cmd isEqualToString:@"sleep"]) { notify_post(PBCmdSleep.UTF8String); return @"ok"; }
    if ([cmd isEqualToString:@"open"]) { notify_post(PBCmdOpen.UTF8String); return @"ok"; }
    if ([cmd isEqualToString:@"status"]) {
        uint64_t f = PBNotifyState(PBFlagsNotification);
        return [NSString stringWithFormat:@"ok foreground=%d volumekeys=%d pinned=%d homescreen=%d",
                !!(f & PBFlagForeground), !!(f & PBFlagVolumeKeys), !!(f & PBFlagPinned), !!(f & PBFlagHomeScreen)];
    }
    return @"error unknown command";
}

static void PBServe(int fd) {
    struct timeval tv = {2, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    char buf[64]; size_t n = 0;
    while (n < sizeof buf - 1) {
        ssize_t r = read(fd, buf + n, 1);
        if (r <= 0 || buf[n] == '\n') break;
        n++;
    }
    buf[n] = 0;
    NSString *cmd = [[[NSString stringWithUTF8String:buf] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    NSString *reply = [PBRun(cmd) stringByAppendingString:@"\n"];
    write(fd, reply.UTF8String, strlen(reply.UTF8String));
    close(fd);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        [[PBUsbListener shared] start];

        int fd = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in a; memset(&a, 0, sizeof a);
        a.sin_len = sizeof a; a.sin_family = AF_INET; a.sin_port = htons(kControlPort); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0 || listen(fd, 8) != 0) {
            NSLog(@"phoneboxd: control port %d is taken, running the tunnel only", kControlPort);
        } else {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                for (;;) {
                    int c = accept(fd, NULL, NULL);
                    if (c < 0) continue;
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ PBServe(c); });
                }
            });
        }
        NSLog(@"phoneboxd: running");
        dispatch_main();
    }
}
