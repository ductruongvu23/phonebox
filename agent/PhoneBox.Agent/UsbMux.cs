using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace PhoneBox.Agent;

/// <summary>An iPhone (or other iOS device) appearing on or leaving the USB bus, as usbmuxd reports it.</summary>
internal sealed record UsbDeviceEvent(bool Attached, long DeviceId, string Serial, string ConnectionType);

/// <summary>
/// A minimal client for usbmuxd, the daemon that talks to iPhones over USB (macOS and Linux: /var/run/usbmuxd,
/// Windows: Apple Mobile Device Service on 127.0.0.1:27015). It only does what PhoneBox needs: list devices coming and
/// going, and open a raw TCP-like tunnel to a port on a device. usbmuxd only lets the PC connect INTO the phone, which
/// is why <see cref="IosUsb"/> keeps a pool of such tunnels waiting.
/// </summary>
internal static class UsbMux
{
    private const uint PlistVersion = 1;
    private const uint MessageTypePlist = 8;
    private const int MaxMessage = 1 << 20;

    /// <summary>"host:port" (TCP), "UNIX:/path" or a bare path, in place of the platform default. Tests, and the
    /// USBMUXD_SOCKET_ADDRESS variable libusbmuxd users already set.</summary>
    internal static string? AddressOverride { get; set; } = Environment.GetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS");

    /// <summary>usbmuxd takes the port in network byte order, written as a host-order integer.</summary>
    internal static int HtonsPort(int port) => ((port & 0xFF) << 8) | ((port >> 8) & 0xFF);

    internal static byte[] Pack(uint tag, IReadOnlyDictionary<string, object> message)
    {
        var body = Encoding.UTF8.GetBytes(ToPlist(message));
        var buf = new byte[16 + body.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(0), (uint)buf.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(4), PlistVersion);
        BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(8), MessageTypePlist);
        BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(12), tag);
        body.CopyTo(buf, 16);
        return buf;
    }

    internal static string ToPlist(IReadOnlyDictionary<string, object> message)
    {
        var doc = new XDocument(new XDeclaration("1.0", "UTF-8", null),
            new XDocumentType("plist", "-//Apple//DTD PLIST 1.0//EN", "http://www.apple.com/DTDs/PropertyList-1.0.dtd", null),
            new XElement("plist", new XAttribute("version", "1.0"), Dict(message)));
        return doc.Declaration + "\n" + doc.DocumentType + "\n" + doc.Root;
    }

    private static XElement Dict(IReadOnlyDictionary<string, object> d)
    {
        var e = new XElement("dict");
        foreach (var (key, value) in d)
        {
            e.Add(new XElement("key", key));
            e.Add(value switch
            {
                string s => new XElement("string", s),
                int i => new XElement("integer", i),
                long l => new XElement("integer", l),
                bool b => new XElement(b ? "true" : "false"),
                IReadOnlyDictionary<string, object> nested => Dict(nested),
                _ => throw new ArgumentException($"unsupported plist value for '{key}'"),
            });
        }
        return e;
    }

    /// <summary>Reads an XML plist into dictionaries, lists, strings, longs, doubles, bools and byte arrays.</summary>
    internal static Dictionary<string, object> ParsePlist(byte[] xml)
    {
        using var reader = XmlReader.Create(new MemoryStream(xml), new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null });
        var doc = XDocument.Load(reader);
        var root = doc.Root?.Elements().FirstOrDefault() ?? throw new InvalidDataException("empty plist");
        return Value(root) as Dictionary<string, object> ?? throw new InvalidDataException("plist is not a dictionary");
    }

    private static object Value(XElement e)
    {
        switch (e.Name.LocalName)
        {
            case "dict":
                var d = new Dictionary<string, object>();
                var items = e.Elements().ToList();
                for (var i = 0; i + 1 < items.Count; i += 2)
                    if (items[i].Name.LocalName == "key") d[items[i].Value] = Value(items[i + 1]);
                return d;
            case "array": return e.Elements().Select(Value).ToList();
            case "integer": return long.Parse(e.Value, System.Globalization.CultureInfo.InvariantCulture);
            case "real": return double.Parse(e.Value, System.Globalization.CultureInfo.InvariantCulture);
            case "true": return true;
            case "false": return false;
            case "data": return Convert.FromBase64String(e.Value.Trim());
            default: return e.Value;
        }
    }

    /// <summary>Reads one framed message; null when the peer closed the connection cleanly between messages.</summary>
    internal static async Task<Dictionary<string, object>?> ReadMessageAsync(Stream s, CancellationToken ct)
    {
        var head = new byte[16];
        var got = 0;
        while (got < head.Length)
        {
            var n = await s.ReadAsync(head.AsMemory(got), ct);
            if (n == 0) { if (got == 0) return null; throw new EndOfStreamException(); }
            got += n;
        }
        var length = BinaryPrimitives.ReadUInt32LittleEndian(head);
        if (length < 16 || length > MaxMessage) throw new InvalidDataException("bad usbmuxd frame length");
        var body = new byte[length - 16];
        await s.ReadExactlyAsync(body, ct);
        return ParsePlist(body);
    }

    internal static async Task<Stream> OpenAsync(CancellationToken ct)
    {
        var addr = AddressOverride;
        if (addr is null && OperatingSystem.IsWindows()) addr = "127.0.0.1:27015";
        if (addr is not null && !addr.StartsWith("UNIX:", StringComparison.OrdinalIgnoreCase) && !addr.StartsWith('/'))
        {
            var i = addr.LastIndexOf(':');
            var host = i > 0 ? addr[..i] : addr;
            var port = i > 0 && int.TryParse(addr[(i + 1)..], out var p) ? p : 27015;
            var tcp = new TcpClient { NoDelay = true };
            try { await tcp.ConnectAsync(host == "localhost" ? "127.0.0.1" : host, port, ct); }
            catch { tcp.Dispose(); throw; }
            return tcp.GetStream();
        }
        var path = addr is null ? "/var/run/usbmuxd" : addr.StartsWith("UNIX:", StringComparison.OrdinalIgnoreCase) ? addr[5..] : addr;
        var sock = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        try { await sock.ConnectAsync(new UnixDomainSocketEndPoint(path), ct); }
        catch { sock.Dispose(); throw; }
        return new NetworkStream(sock, ownsSocket: true);
    }

    private static Dictionary<string, object> Request(string type) => new()
    {
        ["MessageType"] = type,
        ["ClientVersionString"] = "phonebox",
        ["ProgName"] = "phonebox",
        ["kLibUSBMuxVersion"] = 3,
    };

    private static long ResultNumber(Dictionary<string, object>? reply) =>
        reply is not null && reply.TryGetValue("MessageType", out var t) && t as string == "Result" && reply.TryGetValue("Number", out var n) && n is long l ? l : -1;

    /// <summary>
    /// Devices attached now and from here on, until the connection ends (usbmuxd restarted) or the token is cancelled.
    /// Only the first events replay what is already plugged in.
    /// </summary>
    internal static async IAsyncEnumerable<UsbDeviceEvent> ListenAsync([EnumeratorCancellation] CancellationToken ct)
    {
        await using var s = await OpenAsync(ct);
        await s.WriteAsync(Pack(1, Request("Listen")), ct);
        var result = ResultNumber(await ReadMessageAsync(s, ct));
        if (result != 0) throw new IOException($"usbmuxd refused to listen ({result})");
        while (true)
        {
            var m = await ReadMessageAsync(s, ct);
            if (m is null) yield break;
            if (!m.TryGetValue("MessageType", out var type)) continue;
            if (type as string == "Attached" && m.TryGetValue("DeviceID", out var id) && id is long attached)
            {
                var props = m.TryGetValue("Properties", out var pr) ? pr as Dictionary<string, object> : null;
                yield return new UsbDeviceEvent(true, attached,
                    props?.GetValueOrDefault("SerialNumber") as string ?? "",
                    props?.GetValueOrDefault("ConnectionType") as string ?? "");
            }
            else if (type as string == "Detached" && m.TryGetValue("DeviceID", out var gone) && gone is long detached)
                yield return new UsbDeviceEvent(false, detached, "", "");
        }
    }

    /// <summary>Opens a raw tunnel to <paramref name="port"/> on the device. 3 = nothing listens there, 2 = device gone.</summary>
    internal static async Task<Stream> ConnectAsync(long deviceId, int port, CancellationToken ct)
    {
        var s = await OpenAsync(ct);
        try
        {
            var req = Request("Connect");
            req["DeviceID"] = deviceId;
            req["PortNumber"] = HtonsPort(port);
            await s.WriteAsync(Pack(2, req), ct);
            var result = ResultNumber(await ReadMessageAsync(s, ct));
            if (result != 0) throw new IOException($"usbmuxd could not connect to port {port} ({result})");
            return s; // from here on the stream is the device's TCP connection, not usbmuxd messages
        }
        catch
        {
            await s.DisposeAsync();
            throw;
        }
    }
}
