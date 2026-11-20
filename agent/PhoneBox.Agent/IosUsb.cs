using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;

namespace PhoneBox.Agent;

/// <summary>
/// USB for iPhones, the counterpart of <see cref="AdbReverse"/>. iOS has no "adb reverse": usbmuxd only lets the PC
/// connect INTO the phone. So for every iPhone on USB this keeps a few idle usbmuxd connections to port 8767 of the
/// phone, where the PhoneBox app (or its daemon) listens. When the app opens 127.0.0.1:8765 on the phone, it forwards
/// the bytes into one of those idle connections; the first byte arriving here makes this side connect to the agent's
/// own port and pipe both ways, and a replacement idle connection is opened. HTTP and SSE run through unchanged.
/// </summary>
public sealed class IosUsb(ConfigStore cfg, ILogger<IosUsb> log, AgentEndpoint? endpoint = null) : BackgroundService
{
    /// <summary>Port on the iPhone that accepts the idle tunnels (loopback only; usbmuxd arrives from there).</summary>
    public const int DevicePort = 8767;
    internal const int PoolSize = 4;

    private readonly ConcurrentDictionary<long, Device> _devices = new();
    private bool _lastConnected;
    private bool _warned;

    /// <summary>True while at least one iPhone has a tunnel ready for the app to use.</summary>
    public bool Connected => _devices.Values.Any(d => d.Ready > 0);
    /// <summary>Serial numbers of the iPhones on USB (whether or not the app is running).</summary>
    public string[] Devices => [.. _devices.Values.Select(d => d.Serial)];
    public event Action? StateChanged;

    internal int AgentPort => endpoint?.Port ?? 8765;

    private sealed class Device(long id, string serial, CancellationTokenSource cts)
    {
        public long Id { get; } = id;
        public string Serial { get; } = serial;
        public CancellationTokenSource Cts { get; } = cts;
        public int Idle;
        public int Ready => Volatile.Read(ref Idle);
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            if (!cfg.Get().IosUsb) { StopAll(); await Delay(5, ct); continue; }
            try
            {
                await foreach (var e in UsbMux.ListenAsync(ct)) OnEvent(e, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
            catch (Exception ex)
            {
                // no usbmuxd at all is normal on a PC that never saw an iPhone (no iTunes / Apple Devices): say it once
                if (!_warned) { _warned = true; log.LogInformation("iPhone USB support is idle: {Reason}", ex.Message); }
            }
            StopAll();
            await Delay(5, ct);
        }
    }

    private static async Task Delay(double seconds, CancellationToken ct)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(seconds), ct); } catch (OperationCanceledException) { }
    }

    private void OnEvent(UsbDeviceEvent e, CancellationToken ct)
    {
        if (e.Attached)
        {
            // "Network" entries are the same phone seen over Wi-Fi sync; only a cable carries the tunnel
            if (!string.Equals(e.ConnectionType, "USB", StringComparison.OrdinalIgnoreCase) || _devices.ContainsKey(e.DeviceId)) return;
            var d = new Device(e.DeviceId, e.Serial, CancellationTokenSource.CreateLinkedTokenSource(ct));
            if (!_devices.TryAdd(e.DeviceId, d)) return;
            log.LogInformation("iPhone attached ({Serial})", e.Serial);
            _ = Task.Run(() => PoolLoop(d, d.Cts.Token));
            Notify();
        }
        else if (_devices.TryRemove(e.DeviceId, out var gone))
        {
            log.LogInformation("iPhone detached ({Serial})", gone.Serial);
            gone.Cts.Cancel();
            Notify();
        }
    }

    private void StopAll()
    {
        foreach (var id in _devices.Keys.ToArray())
            if (_devices.TryRemove(id, out var d)) d.Cts.Cancel();
        Notify();
    }

    private void Notify()
    {
        var now = Connected || !_devices.IsEmpty;
        if (now == _lastConnected) return;
        _lastConnected = now;
        StateChanged?.Invoke();
    }

    /// <summary>Keeps <see cref="PoolSize"/> idle tunnels open to one phone.</summary>
    private async Task PoolLoop(Device d, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            if (d.Ready >= PoolSize) { await Delay(0.25, ct); continue; }
            try
            {
                var tunnel = await UsbMux.ConnectAsync(d.Id, DevicePort, ct);
                Interlocked.Increment(ref d.Idle);
                _ = Task.Run(() => Serve(d, tunnel, ct));
            }
            catch (OperationCanceledException) { return; }
            catch (Exception)
            {
                // the app is not running (nothing listens on the phone's port yet): look again in a moment
                await Delay(3, ct);
            }
        }
    }

    /// <summary>One idle tunnel: wait for the first byte from the phone, then pipe it to the agent.</summary>
    private async Task Serve(Device d, Stream tunnel, CancellationToken ct)
    {
        var counted = true;
        void Release() { if (counted) { counted = false; Interlocked.Decrement(ref d.Idle); Notify(); } }
        try
        {
            Notify();
            var first = new byte[1];
            var n = await tunnel.ReadAsync(first, ct);
            if (n == 0) { await Delay(1, ct); return; } // the phone closed it: the loop opens a fresh one
            Release(); // in use now: the pool opens a replacement
            using var local = new TcpClient { NoDelay = true };
            await local.ConnectAsync(IPAddress.Loopback, AgentPort, ct);
            var agent = local.GetStream();
            await agent.WriteAsync(first, ct);
            await Pipe(tunnel, agent, ct);
        }
        catch (Exception) { /* a dropped tunnel is not an error: the phone reconnects */ }
        finally
        {
            Release();
            await tunnel.DisposeAsync();
        }
    }

    internal static async Task Pipe(Stream a, Stream b, CancellationToken ct)
    {
        using var both = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var t1 = a.CopyToAsync(b, both.Token);
        var t2 = b.CopyToAsync(a, both.Token);
        await Task.WhenAny(t1, t2);
        both.Cancel();
        try { await Task.WhenAll(t1, t2); } catch (Exception) { }
    }
}
