using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Channels;
using Microsoft.Extensions.Logging.Abstractions;
using PhoneBox.Agent;
using Xunit;

/// <summary>
/// The usbmuxd client and the iPhone tunnel pool, against a fake usbmuxd on loopback TCP (never a real phone or the
/// real usbmuxd). The tests share <see cref="UsbMux.AddressOverride"/>, so they run one at a time.
/// </summary>
[Collection("usbmux")]
public sealed class UsbMuxTests : IDisposable
{
    private readonly string? _savedAddress = UsbMux.AddressOverride;
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "phonebox-usbmux-" + Guid.NewGuid().ToString("N"));
    public UsbMuxTests() => Directory.CreateDirectory(_dir);
    public void Dispose() { UsbMux.AddressOverride = _savedAddress; try { Directory.Delete(_dir, true); } catch { } }

    [Fact]
    public void Pack_writes_the_16_byte_header_then_an_xml_plist()
    {
        var buf = UsbMux.Pack(7, new Dictionary<string, object> { ["MessageType"] = "Listen", ["kLibUSBMuxVersion"] = 3 });
        Assert.Equal((uint)buf.Length, BinaryPrimitives.ReadUInt32LittleEndian(buf));
        Assert.Equal(1u, BinaryPrimitives.ReadUInt32LittleEndian(buf.AsSpan(4)));  // plist protocol
        Assert.Equal(8u, BinaryPrimitives.ReadUInt32LittleEndian(buf.AsSpan(8)));  // message type
        Assert.Equal(7u, BinaryPrimitives.ReadUInt32LittleEndian(buf.AsSpan(12))); // tag
        var xml = Encoding.UTF8.GetString(buf, 16, buf.Length - 16);
        Assert.Contains("<key>MessageType</key>", xml);
        Assert.Contains("<string>Listen</string>", xml);
        Assert.Contains("<integer>3</integer>", xml);
    }

    [Fact]
    public void The_port_goes_out_in_network_byte_order()
    {
        Assert.Equal(0x3F22, UsbMux.HtonsPort(8767)); // 8767 = 0x223F
        Assert.Equal(0x3D22, UsbMux.HtonsPort(8765));
    }

    [Fact]
    public void ParsePlist_reads_an_attach_message()
    {
        const string xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>DeviceID</key><integer>12</integer>
              <key>MessageType</key><string>Attached</string>
              <key>Properties</key><dict>
                <key>ConnectionType</key><string>USB</string>
                <key>SerialNumber</key><string>00008030-001234567890802E</string>
                <key>Flag</key><true/>
              </dict>
            </dict></plist>
            """;
        var m = UsbMux.ParsePlist(Encoding.UTF8.GetBytes(xml));
        Assert.Equal(12L, m["DeviceID"]);
        Assert.Equal("Attached", m["MessageType"]);
        var props = Assert.IsType<Dictionary<string, object>>(m["Properties"]);
        Assert.Equal("USB", props["ConnectionType"]);
        Assert.Equal(true, props["Flag"]);
    }

    [Fact]
    public async Task A_packed_message_reads_back()
    {
        var ms = new MemoryStream(UsbMux.Pack(1, new Dictionary<string, object> { ["MessageType"] = "Result", ["Number"] = 0 }));
        var m = await UsbMux.ReadMessageAsync(ms, CancellationToken.None);
        Assert.NotNull(m);
        Assert.Equal("Result", m!["MessageType"]);
        Assert.Equal(0L, m["Number"]);
        Assert.Null(await UsbMux.ReadMessageAsync(ms, CancellationToken.None)); // clean end between messages
    }

    [Fact]
    public async Task A_frame_with_an_absurd_length_is_refused()
    {
        var head = new byte[16];
        BinaryPrimitives.WriteUInt32LittleEndian(head, uint.MaxValue);
        await Assert.ThrowsAsync<InvalidDataException>(() => UsbMux.ReadMessageAsync(new MemoryStream(head), CancellationToken.None));
    }

    /// <summary>Stands in for usbmuxd: announces one USB iPhone and a Wi-Fi-only one, hands out tunnels on Connect.</summary>
    private sealed class FakeMux : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly List<TcpClient> _clients = [];
        public Channel<Stream> Tunnels { get; } = Channel.CreateUnbounded<Stream>();
        public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;
        public long? RequestedPort;

        public FakeMux() { _listener.Start(); _ = Task.Run(AcceptLoop); }

        private async Task AcceptLoop()
        {
            while (true)
            {
                TcpClient c;
                try { c = await _listener.AcceptTcpClientAsync(); } catch { return; }
                lock (_clients) _clients.Add(c);
                _ = Task.Run(() => Handle(c));
            }
        }

        private static byte[] Attached(long id, string connection, string serial) => UsbMux.Pack(0, new Dictionary<string, object>
        {
            ["MessageType"] = "Attached",
            ["DeviceID"] = id,
            ["Properties"] = new Dictionary<string, object> { ["ConnectionType"] = connection, ["SerialNumber"] = serial },
        });

        private static Task Reply(Stream s, long number) =>
            s.WriteAsync(UsbMux.Pack(1, new Dictionary<string, object> { ["MessageType"] = "Result", ["Number"] = number })).AsTask();

        private async Task Handle(TcpClient c)
        {
            try
            {
                var s = c.GetStream();
                var m = await UsbMux.ReadMessageAsync(s, CancellationToken.None);
                if (m is null) return;
                switch (m["MessageType"] as string)
                {
                    case "Listen":
                        await Reply(s, 0);
                        await s.WriteAsync(Attached(9, "USB", "SERIAL-USB"));
                        await s.WriteAsync(Attached(10, "Network", "SERIAL-WIFI"));
                        await Task.Delay(Timeout.Infinite); // stays open, like the real one
                        break;
                    case "Connect":
                        RequestedPort = m["PortNumber"] as long?;
                        if (m["DeviceID"] as long? != 9) { await Reply(s, 2); return; }
                        await Reply(s, 0);
                        Tunnels.Writer.TryWrite(s); // from here the stream is the phone's TCP connection
                        await Task.Delay(Timeout.Infinite);
                        break;
                }
            }
            catch { }
        }

        public void Dispose()
        {
            _listener.Stop();
            lock (_clients) foreach (var c in _clients) c.Dispose();
        }
    }

    private static CancellationToken Timeout10s() => new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token;

    [Fact]
    public async Task ListenAsync_reports_the_devices_that_are_attached()
    {
        using var mux = new FakeMux();
        UsbMux.AddressOverride = $"127.0.0.1:{mux.Port}";
        var seen = new List<UsbDeviceEvent>();
        await foreach (var e in UsbMux.ListenAsync(Timeout10s()))
        {
            seen.Add(e);
            if (seen.Count == 2) break;
        }
        Assert.Contains(seen, e => e.DeviceId == 9 && e.ConnectionType == "USB" && e.Serial == "SERIAL-USB");
        Assert.Contains(seen, e => e.DeviceId == 10 && e.ConnectionType == "Network");
    }

    [Fact]
    public async Task ConnectAsync_asks_for_the_port_and_returns_the_raw_tunnel()
    {
        using var mux = new FakeMux();
        UsbMux.AddressOverride = $"127.0.0.1:{mux.Port}";
        await using var tunnel = await UsbMux.ConnectAsync(9, IosUsb.DevicePort, Timeout10s());
        Assert.Equal((long)UsbMux.HtonsPort(IosUsb.DevicePort), mux.RequestedPort);
        var phone = await mux.Tunnels.Reader.ReadAsync(Timeout10s());
        await phone.WriteAsync("hi"u8.ToArray());
        var got = new byte[2];
        await tunnel.ReadExactlyAsync(got, Timeout10s());
        Assert.Equal("hi", Encoding.ASCII.GetString(got));
    }

    [Fact]
    public async Task ConnectAsync_to_a_device_that_is_gone_throws()
    {
        using var mux = new FakeMux();
        UsbMux.AddressOverride = $"127.0.0.1:{mux.Port}";
        await Assert.ThrowsAsync<IOException>(() => UsbMux.ConnectAsync(77, IosUsb.DevicePort, Timeout10s()));
    }

    [Fact]
    public async Task IosUsb_pipes_the_first_byte_and_the_rest_to_the_agent_and_back()
    {
        // the "agent": answers "pong" to whatever it receives
        var agent = new TcpListener(IPAddress.Loopback, 0);
        agent.Start();
        var agentPort = ((IPEndPoint)agent.LocalEndpoint).Port;
        var received = new TaskCompletionSource<string>();
        _ = Task.Run(async () =>
        {
            using var c = await agent.AcceptTcpClientAsync();
            var s = c.GetStream();
            var buf = new byte[4];
            await s.ReadExactlyAsync(buf);
            received.SetResult(Encoding.ASCII.GetString(buf));
            await s.WriteAsync("pong"u8.ToArray());
            await Task.Delay(500);
        });

        using var mux = new FakeMux();
        UsbMux.AddressOverride = $"127.0.0.1:{mux.Port}";
        var cfgPath = Path.Combine(_dir, "config.json");
        using var ios = new IosUsb(new ConfigStore(cfgPath), NullLogger<IosUsb>.Instance, new AgentEndpoint(agentPort));
        await ios.StartAsync(CancellationToken.None);
        try
        {
            // the pool fills with idle tunnels (only the USB device gets any)
            var phone = await mux.Tunnels.Reader.ReadAsync(Timeout10s());
            await phone.WriteAsync("ping"u8.ToArray());        // the app's request, spliced in by the phone
            Assert.Equal("ping", await received.Task.WaitAsync(TimeSpan.FromSeconds(10)));
            var reply = new byte[4];
            await phone.ReadExactlyAsync(reply, Timeout10s());
            Assert.Equal("pong", Encoding.ASCII.GetString(reply));
            Assert.Equal(new[] { "SERIAL-USB" }, ios.Devices);          // the Wi-Fi-only entry is not a cable
        }
        finally
        {
            await ios.StopAsync(CancellationToken.None);
            agent.Stop();
        }
    }
}
