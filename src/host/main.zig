const std = @import("std");
const qemu = @import("qemu.zig");
const ws_client = @import("ws_client.zig");
const protocol = @import("protocol");

const log = std.log.scoped(.vmctl);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "start")) {
        try cmdStart(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "exec")) {
        try cmdExec(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "stop")) {
        try cmdStop(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "install")) {
        try cmdInstall(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "web")) {
        try cmdWeb(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "help")) {
        printUsage();
    } else {
        log.err("unknown command: {s}", .{command});
        printUsage();
    }
}

fn printUsage() void {
    const usage =
        \\Usage: vmctl <command> [options]
        \\
        \\Commands:
        \\  start <rootfs.img> [opts]   Start VM with the given root filesystem
        \\  exec <port> [--raw] -- cmd  Execute command in running VM
        \\  install <port> <file>       Install binary to /usr/local/bin in VM
        \\  web <port> [http-port]      Serve web terminal (default: 8000)
        \\  stop <port>                 Stop VM on given port
        \\  help                        Show this help
        \\
        \\Start options:
        \\  --kernel <path>             Kernel image (default: auto-detect)
        \\  --initrd <path>             Initrd image (default: auto-detect)
        \\  --share <host-path> <tag>   Share directory via virtio-9p
        \\
        \\Examples:
        \\  vmctl start ./image-builder/artifacts/rootfs.img
        \\  vmctl exec 8080 -- echo hello
        \\  vmctl exec 8080 --raw -- whoami
        \\  vmctl install 8080 ./myapp
        \\  vmctl web 8080
        \\  vmctl stop 8080
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn cmdStart(parent_allocator: std.mem.Allocator, args: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (args.len < 1) {
        log.err("missing rootfs path", .{});
        return;
    }

    const rootfs = args[0];

    var share_paths = std.ArrayListUnmanaged(qemu.SharePath){};

    var kernel: ?[]const u8 = null;
    var initrd: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--share") and i + 2 < args.len) {
            try share_paths.append(allocator, .{
                .host = args[i + 1],
                .tag = args[i + 2],
            });
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--kernel") and i + 1 < args.len) {
            kernel = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--initrd") and i + 1 < args.len) {
            initrd = args[i + 1];
            i += 1;
        }
    }

    // Auto-detect kernel/initrd from same directory as rootfs
    if (kernel == null) {
        const dir = std.fs.path.dirname(rootfs) orelse ".";
        const kernel_path = try std.fmt.allocPrint(allocator, "{s}/vmlinuz", .{dir});
        if (std.fs.cwd().access(kernel_path, .{})) |_| {
            kernel = kernel_path;
            const initrd_path = try std.fmt.allocPrint(allocator, "{s}/initrd.img", .{dir});
            if (std.fs.cwd().access(initrd_path, .{})) |_| {
                initrd = initrd_path;
            } else |_| {}
        } else |_| {}
    }

    const port = try qemu.findFreePort();

    // Create share directory for file transfers
    const tmp_share = try std.fmt.allocPrint(allocator, "/tmp/vmctl-{d}", .{port});
    std.fs.makeDirAbsolute(tmp_share) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try share_paths.append(allocator, .{ .host = tmp_share, .tag = "vmctl" });

    var vm = qemu.Qemu.init(allocator, .{
        .rootfs = rootfs,
        .kernel = kernel,
        .initrd = initrd,
        .cpus = 4,
        .memory_mb = 4096,
        .host_port = port,
        .share_paths = share_paths.items,
    });

    log.info("starting VM with {s}...", .{rootfs});
    try vm.start();

    log.info("VM started on port {d}", .{port});
    log.info("share dir: {s}", .{tmp_share});
    std.debug.print("{d}\n", .{port});
}

var g_exit_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_exit_code: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

fn cmdExec(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        log.err("missing port", .{});
        return;
    }

    const port = try std.fmt.parseInt(u16, args[0], 10);

    var cmd_start: usize = 1;
    var raw_mode = false;
    for (args[1..], 1..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--raw")) {
            raw_mode = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            cmd_start = idx + 1;
            break;
        }
    }

    if (cmd_start >= args.len) {
        log.err("missing command after --", .{});
        return;
    }

    const command = args[cmd_start];
    const cmd_args = if (cmd_start + 1 < args.len) args[cmd_start + 1 ..] else &[_][]const u8{};

    var client = try ws_client.Client.connect(allocator, "127.0.0.1", port);
    defer client.close();

    client.callbacks = .{
        .onStdout = struct {
            fn f(_: u32, data: []const u8) void {
                std.fs.File.stdout().writeAll(data) catch {};
            }
        }.f,
        .onStderr = struct {
            fn f(_: u32, data: []const u8) void {
                std.fs.File.stderr().writeAll(data) catch {};
            }
        }.f,
        .onExit = struct {
            fn f(_: u32, code: i32) void {
                g_exit_code.store(code, .release);
                g_exit_flag.store(true, .release);
            }
        }.f,
        .onSpawned = null,
        .onError = struct {
            fn f(_: u32, _: i32, message: []const u8) void {
                std.fs.File.stderr().writeAll("error: ") catch {};
                std.fs.File.stderr().writeAll(message) catch {};
                std.fs.File.stderr().writeAll("\n") catch {};
                g_exit_flag.store(true, .release);
            }
        }.f,
    };

    var result = if (raw_mode) try client.spawnRaw(command, cmd_args) else try client.spawn(command, cmd_args);
    defer result.deinit();

    // Spawn thread to forward stdin
    const stdin_thread = std.Thread.spawn(.{}, forwardStdin, .{ client, result.id, result.handle }) catch null;
    defer if (stdin_thread) |t| t.join();

    // Wait for exit
    while (!g_exit_flag.load(.acquire)) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    std.process.exit(@intCast(@max(0, g_exit_code.load(.acquire))));
}

fn forwardStdin(client: *ws_client.Client, id: u32, handle: []const u8) void {
    const stdin = std.fs.File.stdin();
    var buf: [4096]u8 = undefined;

    while (!g_exit_flag.load(.acquire)) {
        const n = stdin.read(&buf) catch break;
        if (n == 0) break;
        client.sendStdin(id, handle, buf[0..n]) catch break;
    }
}

fn cmdStop(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        log.err("missing port", .{});
        return;
    }

    const port = try std.fmt.parseInt(u16, args[0], 10);
    log.info("stopping VM on port {d}...", .{port});

    // Find and kill QEMU process with this port forwarding
    const pattern = try std.fmt.allocPrint(allocator, "hostfwd=tcp::{d}-", .{port});
    defer allocator.free(pattern);

    var child = std.process.Child.init(&.{ "pkill", "-f", pattern }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    _ = try child.spawnAndWait();
    log.info("VM stopped", .{});
}

fn cmdWeb(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        log.err("usage: vmctl web <vm-port> [http-port]", .{});
        return;
    }

    const vm_port = try std.fmt.parseInt(u16, args[0], 10);
    const http_port: u16 = if (args.len > 1) try std.fmt.parseInt(u16, args[1], 10) else 8000;

    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, http_port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    log.info("serving web terminal at http://0.0.0.0:{d} -> VM port {d}", .{ http_port, vm_port });

    while (true) {
        const conn = server.accept() catch continue;
        _ = std.Thread.spawn(.{}, handleHttpConnection, .{ conn, vm_port, allocator }) catch {
            conn.stream.close();
            continue;
        };
    }
}

fn handleHttpConnection(conn: std.net.Server.Connection, vm_port: u16, allocator: std.mem.Allocator) void {
    defer conn.stream.close();

    var buf: [4096]u8 = undefined;
    const n = conn.stream.read(&buf) catch return;
    if (n == 0) return;

    const request = buf[0..n];

    // Check for WebSocket upgrade
    if (std.mem.indexOf(u8, request, "Upgrade: websocket") != null) {
        handleWebSocketProxy(conn.stream, request, vm_port, allocator);
        return;
    }

    // Serve static HTML
    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <title>VM Terminal</title>
        \\  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css">
        \\  <style>
        \\    body { margin: 0; background: #1e1e1e; font-family: system-ui; }
        \\    #controls { padding: 10px; background: #2d2d2d; display: flex; gap: 10px; align-items: center; }
        \\    #controls input, #controls button { padding: 8px 12px; border: 1px solid #555; border-radius: 4px; }
        \\    #controls input { background: #1e1e1e; color: #fff; width: 100px; }
        \\    #controls button { background: #0078d4; color: #fff; border: none; cursor: pointer; }
        \\    #controls button:hover { background: #106ebe; }
        \\    #controls button:disabled { background: #555; cursor: not-allowed; }
        \\    #status { color: #888; margin-left: auto; }
        \\    #terminal { height: calc(100vh - 50px); }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div id="controls">
        \\    <input type="text" id="cmd" placeholder="Command" value="/bin/bash -i">
        \\    <button id="connect">Connect</button>
        \\    <button id="disconnect" disabled>Disconnect</button>
        \\    <span id="status">Disconnected</span>
        \\  </div>
        \\  <div id="terminal"></div>
        \\
        \\  <script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.min.js"></script>
        \\  <script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.min.js"></script>
        \\  <script>
        \\    const term = new Terminal({ cursorBlink: true, fontSize: 14 });
        \\    const fitAddon = new FitAddon.FitAddon();
        \\    term.loadAddon(fitAddon);
        \\    term.open(document.getElementById('terminal'));
        \\    fitAddon.fit();
        \\    window.addEventListener('resize', () => { fitAddon.fit(); sendResize(); });
        \\
        \\    let ws = null;
        \\    let processId = null;
        \\    let processHandle = null;
        \\
        \\    const $ = id => document.getElementById(id);
        \\    const setStatus = s => $('status').textContent = s;
        \\
        \\    function encodeMessage(type, payload) {
        \\      const json = JSON.stringify(payload);
        \\      const buf = new ArrayBuffer(5 + json.length);
        \\      const view = new DataView(buf);
        \\      view.setUint8(0, type);
        \\      view.setUint32(1, json.length, true);
        \\      new TextEncoder().encodeInto(json, new Uint8Array(buf, 5));
        \\      return buf;
        \\    }
        \\
        \\    function decodeMessage(buf) {
        \\      const view = new DataView(buf);
        \\      const type = view.getUint8(0);
        \\      const len = view.getUint32(1, true);
        \\      const json = new TextDecoder().decode(new Uint8Array(buf, 5, len));
        \\      return { type, payload: JSON.parse(json) };
        \\    }
        \\
        \\    const MSG = { spawn: 0x01, stdin: 0x02, resize: 0x04, spawned: 0x81, stdout: 0x82, stderr: 0x83, exit: 0x84, error: 0x85 };
        \\
        \\    function sendResize() {
        \\      if (ws && processHandle) {
        \\        ws.send(encodeMessage(MSG.resize, { id: processId, handle: processHandle, rows: term.rows, cols: term.cols }));
        \\      }
        \\    }
        \\
        \\    $('connect').onclick = () => {
        \\      const parts = $('cmd').value.split(' ');
        \\      const cmd = parts[0];
        \\      const args = parts.slice(1);
        \\      ws = new WebSocket(`ws://${location.host}/ws`);
        \\      ws.binaryType = 'arraybuffer';
        \\      setStatus('Connecting...');
        \\
        \\      ws.onopen = () => {
        \\        setStatus('Connected, spawning...');
        \\        processId = 1;
        \\        ws.send(encodeMessage(MSG.spawn, { id: processId, command: cmd, args: args, network: true, pty: true }));
        \\        $('connect').disabled = true;
        \\        $('disconnect').disabled = false;
        \\      };
        \\
        \\      ws.onmessage = e => {
        \\        const msg = decodeMessage(e.data);
        \\        switch (msg.type) {
        \\          case MSG.spawned:
        \\            processHandle = msg.payload.handle;
        \\            setStatus(`Running (PID ${msg.payload.pid})`);
        \\            term.focus();
        \\            sendResize();
        \\            break;
        \\          case MSG.stdout:
        \\          case MSG.stderr:
        \\            term.write(msg.payload.data);
        \\            break;
        \\          case MSG.exit:
        \\            setStatus(`Exited (code ${msg.payload.code})`);
        \\            break;
        \\          case MSG.error:
        \\            term.write(`\r\nError: ${msg.payload.message}\r\n`);
        \\            break;
        \\        }
        \\      };
        \\
        \\      ws.onclose = () => {
        \\        setStatus('Disconnected');
        \\        $('connect').disabled = false;
        \\        $('disconnect').disabled = true;
        \\        ws = null;
        \\      };
        \\
        \\      ws.onerror = () => setStatus('Connection error');
        \\    };
        \\
        \\    $('disconnect').onclick = () => ws?.close();
        \\
        \\    term.onData(data => {
        \\      if (ws && processHandle) {
        \\        ws.send(encodeMessage(MSG.stdin, { id: processId, handle: processHandle, data }));
        \\      }
        \\    });
        \\  </script>
        \\</body>
        \\</html>
    ;

    const response = std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ html.len, html }) catch return;
    defer allocator.free(response);
    conn.stream.writeAll(response) catch {};
}

fn handleWebSocketProxy(stream: std.net.Stream, request: []const u8, vm_port: u16, allocator: std.mem.Allocator) void {
    // Extract Sec-WebSocket-Key
    const key_start = std.mem.indexOf(u8, request, "Sec-WebSocket-Key: ") orelse return;
    const key_line = request[key_start + 19 ..];
    const key_end = std.mem.indexOf(u8, key_line, "\r\n") orelse return;
    const key = key_line[0..key_end];

    // Compute accept key
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(magic);
    var hash: [20]u8 = undefined;
    hasher.final(&hash);

    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &hash);

    // Send upgrade response
    const upgrade = std.fmt.allocPrint(allocator, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch return;
    defer allocator.free(upgrade);
    stream.writeAll(upgrade) catch return;

    // Connect to VM
    const vm_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, vm_port);
    var vm_stream = std.net.tcpConnectToAddress(vm_addr) catch return;
    defer vm_stream.close();

    // Send WebSocket handshake to VM
    const ws_key = "dGhlIHNhbXBsZSBub25jZQ==";
    const vm_handshake = std.fmt.allocPrint(allocator, "GET / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ vm_port, ws_key }) catch return;
    defer allocator.free(vm_handshake);
    vm_stream.writeAll(vm_handshake) catch return;

    // Read VM handshake response
    var vm_buf: [1024]u8 = undefined;
    _ = vm_stream.read(&vm_buf) catch return;

    // Proxy data between browser and VM
    const browser_to_vm = std.Thread.spawn(.{}, proxyData, .{ stream, vm_stream }) catch return;
    defer browser_to_vm.join();
    proxyData(vm_stream, stream);
}

fn proxyData(src: std.net.Stream, dst: std.net.Stream) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = src.read(&buf) catch break;
        if (n == 0) break;
        dst.writeAll(buf[0..n]) catch break;
    }
}

fn cmdInstall(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        log.err("usage: vmctl install <port> <file>", .{});
        return;
    }

    const port = try std.fmt.parseInt(u16, args[0], 10);
    const file_path = args[1];

    const basename = std.fs.path.basename(file_path);
    const share_dir = try std.fmt.allocPrint(allocator, "/tmp/vmctl-{d}", .{port});
    defer allocator.free(share_dir);

    const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ share_dir, basename });
    defer allocator.free(dest_path);

    // Copy file to share directory
    const src = try std.fs.cwd().openFile(file_path, .{});
    defer src.close();
    const dest = try std.fs.createFileAbsolute(dest_path, .{});
    defer dest.close();

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dest.writeAll(buf[0..n]);
    }

    // Connect to VM and run install script
    var client = try ws_client.Client.connect(allocator, "127.0.0.1", port);
    defer client.close();

    const script = try std.fmt.allocPrint(allocator,
        \\mkdir -p /mnt/vmctl
        \\mountpoint -q /mnt/vmctl || mount -t 9p vmctl /mnt/vmctl
        \\cp /mnt/vmctl/{s} /usr/local/bin/
        \\chmod +x /usr/local/bin/{s}
    , .{ basename, basename });
    defer allocator.free(script);

    g_exit_flag.store(false, .release);
    client.callbacks = .{
        .onStderr = struct {
            fn f(_: u32, data: []const u8) void {
                std.fs.File.stderr().writeAll(data) catch {};
            }
        }.f,
        .onExit = struct {
            fn f(_: u32, code: i32) void {
                g_exit_code.store(code, .release);
                g_exit_flag.store(true, .release);
            }
        }.f,
        .onError = struct {
            fn f(_: u32, _: i32, message: []const u8) void {
                std.fs.File.stderr().writeAll("error: ") catch {};
                std.fs.File.stderr().writeAll(message) catch {};
                std.fs.File.stderr().writeAll("\n") catch {};
                g_exit_flag.store(true, .release);
            }
        }.f,
    };

    log.info("copying {s}...", .{basename});
    var result = try client.spawnRaw("/bin/sh", &.{ "-c", script });
    defer result.deinit();

    while (!g_exit_flag.load(.acquire)) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    if (g_exit_code.load(.acquire) == 0) {
        log.info("installed {s}", .{basename});
    } else {
        log.err("install failed", .{});
    }
}
