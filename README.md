# kage

Lightweight VM sandbox using QEMU with HVF acceleration. Written in Zig.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Host (macOS)                                   │
│                                                                             │
│  ┌──────────────┐                                                           │
│  │    vmctl     │  CLI tool                                                 │
│  │    (Zig)     │  - Spawns QEMU with HVF                                   │
│  └──────┬───────┘  - WebSocket client                                       │
│         │                                                                   │
│         │ spawns                                                            │
│         ▼                                                                   │
│  ┌──────────────┐         ┌─────────────────────────────────────────────┐   │
│  │    QEMU      │ hostfwd │              Linux VM (Ubuntu ARM64)        │   │
│  │   (HVF)      │◄───────►│                                             │   │
│  └──────────────┘  :8080  │  ┌─────────────────────────────────────┐    │   │
│                           │  │              vmd (Zig)              │    │   │
│                           │  │  - WebSocket server on :8080        │    │   │
│                           │  │  - Process spawning with PTY        │    │   │
│                           │  │  - Session/user management          │    │   │
│                           │  └──────────────┬──────────────────────┘    │   │
│                           │                 │                           │   │
│                           │                 │ wraps                     │   │
│                           │                 ▼                           │   │
│                           │  ┌─────────────────────────────────────┐    │   │
│                           │  │       sandbox-helper (Zig)          │    │   │
│                           │  │  - Linux namespaces                 │    │   │
│                           │  │  - Seccomp filtering                │    │   │
│                           │  │  - Network isolation                │    │   │
│                           │  └─────────────────────────────────────┘    │   │
│                           └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Build everything
zig build

# Build the VM image (requires Docker)
cd image-builder && ./build.sh

# Start VM (returns port number)
./zig-out/bin/vmctl start ./image-builder/artifacts/rootfs.img
# => 52383

# Execute commands
./zig-out/bin/vmctl exec 52383 -- echo "Hello from VM"
./zig-out/bin/vmctl exec 52383 -- ls -la

# Web terminal
./zig-out/bin/vmctl web 52383
# Open http://localhost:8000

# Stop VM
./zig-out/bin/vmctl stop 52383
```

## Commands

### start

```bash
vmctl start <rootfs.img> [options]
```

Options:
- `--kernel <path>` - Kernel image (default: auto-detected from rootfs dir)
- `--initrd <path>` - Initrd image (default: auto-detected from rootfs dir)
- `--share <host-path> <tag>` - Share host directory via virtio-9p

### exec

```bash
vmctl exec <port> [--raw] -- <command> [args...]
```

Options:
- `--raw` - Bypass sandbox (run as root with network access)

Stdin is forwarded, stdout/stderr streamed back. Exit code preserved.

### install

```bash
vmctl install <port> <file>
```

Copies a binary to `/usr/local/bin` in the VM via virtio-9p share.

### web

```bash
vmctl web <port> [http-port]
```

Starts a web server with an xterm.js terminal connected to the VM.
Default HTTP port is 8000. Supports PTY for full terminal emulation.

### stop

```bash
vmctl stop <port>
```

## Protocol

Binary WebSocket frames: `[type:u8][len:u32 LE][json payload]`

### Requests (host → guest)

| Type | Name | Payload |
|------|------|---------|
| 0x01 | spawn | `{id, command, args, cwd?, uid?, gid?, network?, pty?}` |
| 0x02 | stdin | `{id, handle, data}` |
| 0x03 | kill | `{handle, signal?}` |
| 0x04 | resize | `{id, handle, rows, cols}` |
| 0x05 | mount | `{tag, mount_point, read_only?}` |
| 0x06 | unmount | `{mount_point}` |
| 0x07 | session_create | `{uid, username?}` |
| 0x08 | binary_install | `{name, data, executable?}` |

### Responses (guest → host)

| Type | Name | Payload |
|------|------|---------|
| 0x81 | spawned | `{id, pid, handle}` |
| 0x82 | stdout | `{id, data}` |
| 0x83 | stderr | `{id, data}` |
| 0x84 | exit | `{id, code, signal?}` |
| 0x85 | error | `{id, code, message}` |
| 0x86 | ok | `{}` |

## Project Structure

```
kage/
├── src/
│   ├── host/           # vmctl CLI, QEMU launcher, WebSocket client
│   ├── guest/          # vmd daemon, WebSocket server, process management
│   └── shared/         # Protocol definitions
├── sandbox-helper/     # Namespace isolation with seccomp
├── image-builder/      # Scripts to build Ubuntu rootfs
└── build.zig
```

## Requirements

- macOS 14+ with Apple Silicon (HVF)
- QEMU (`brew install qemu`)
- Zig 0.15+
- Docker (for building VM images)

## License

MIT
