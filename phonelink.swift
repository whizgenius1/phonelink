// phonelink — use an Android phone as a secondary device for your Mac's mouse and keyboard.
//
// Push the cursor past the configured screen edge and it "moves onto" the phone: a real
// Android mouse pointer appears there and the keyboard types into the phone. Push back
// across the phone's near edge (or press ⌃⌥Space) to return to the Mac.
//
// No mirroring. On the phone side it reuses scrcpy's tiny on-device server purely as an
// input injector (virtual USB HID keyboard + mouse via UHID), launched headless over adb.

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Darwin

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

// MARK: - Config

let phonelinkVersion = "1.0.0"

enum Edge: String { case left, right }

struct Config {
    var edge: Edge = .right
    var serial: String? = nil
    var cmdAsCtrl = true      // left ⌘ → Ctrl on the phone, so ⌘C/⌘V/⌘A work as expected
    var verbose = false
    var speed = 2.0           // phone pointer speed multiplier
    var clipboard = true      // share the clipboard between Mac and phone
    var selfTest = false      // connect, wiggle the phone pointer (no clicks), exit
    var sendPaths: [String] = []  // --send: copy these files to the phone and exit
}

func usage() -> Never {
    print("""
    usage: phonelink [--version] [--edge right|left] [--serial SERIAL] [--speed N] [--no-cmd-as-ctrl] [--no-clipboard] [--verbose]

      --edge             which side of your Mac screens the phone sits on (default: right)
      --serial           adb serial to use (default: first connected device)
      --speed            phone pointer speed multiplier (default: 2.0)
      --no-cmd-as-ctrl   send ⌘ as Meta instead of Ctrl
      --no-clipboard     don't share the clipboard
      --send FILE...     copy files/folders to the phone's Download folder and exit
                         (works while phonelink is running; put it last)
    Hotkey: ⌃⌥Space toggles between Mac and phone.

    Options can also be put in ~/.config/phonelink/config (same flags, one or more
    per line, # for comments); command-line flags are applied after it.
    """)
    exit(2)
}

// Flags from ~/.config/phonelink/config — lets `brew services` (which can't pass
// arguments) still pick a device, speed, etc.
func configFileArgs() -> [String] {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let path = home + "/.config/phonelink/config"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").flatMap { line -> [String] in
        let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return content.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }
}

func parseArgs() -> Config {
    var c = Config()
    var it = (configFileArgs() + CommandLine.arguments.dropFirst()).makeIterator()
    while let a = it.next() {
        switch a {
        case "--edge": guard let v = it.next(), let e = Edge(rawValue: v) else { usage() }; c.edge = e
        case "--serial", "-s": guard let v = it.next() else { usage() }; c.serial = v
        case "--no-cmd-as-ctrl": c.cmdAsCtrl = false
        case "--no-clipboard": c.clipboard = false
        case "--verbose", "-v": c.verbose = true
        case "--speed": guard let v = it.next(), let x = Double(v), x > 0 else { usage() }; c.speed = x
        case "--self-test": c.selfTest = true
        case "--version": print("phonelink \(phonelinkVersion)"); exit(0)
        case "--send":
            while let v = it.next() { c.sendPaths.append(v) }
            if c.sendPaths.isEmpty { usage() }
        default: usage()
        }
    }
    return c
}

let config = parseArgs()

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
}

// MARK: - Tools discovery

func firstExisting(_ paths: [String]) -> String? {
    paths.first { FileManager.default.isExecutableFile(atPath: $0) || FileManager.default.fileExists(atPath: $0) }
}

let home = NSHomeDirectory()
let adb: String = firstExisting([
    "/usr/local/bin/adb", "/opt/homebrew/bin/adb", "\(home)/Library/Android/sdk/platform-tools/adb",
]) ?? { print("adb not found"); exit(1) }()

let serverPath: String = firstExisting([
    ProcessInfo.processInfo.environment["SCRCPY_SERVER_PATH"] ?? "",
    "/usr/local/share/scrcpy/scrcpy-server", "/opt/homebrew/share/scrcpy/scrcpy-server",
]) ?? { print("scrcpy-server not found (brew install scrcpy)"); exit(1) }()

@discardableResult
func run(_ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// The on-device server refuses to run unless the client version matches exactly.
let serverVersion: String = {
    for bin in ["/usr/local/bin/scrcpy", "/opt/homebrew/bin/scrcpy"] where FileManager.default.isExecutableFile(atPath: bin) {
        let out = run([bin, "--version"]).out
        if let first = out.split(separator: "\n").first {
            let parts = first.split(separator: " ")
            if parts.count >= 2, parts[0] == "scrcpy" { return String(parts[1]) }
        }
    }
    print("could not determine scrcpy version"); exit(1)
}()

// MARK: - HID descriptors (same as scrcpy's, so the server accepts them)

let hidKeyboardID: UInt16 = 1
let hidMouseID: UInt16 = 2

let keyboardReportDesc: [UInt8] = [
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x75, 0x08, 0x95, 0x01, 0x81, 0x01,
    0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x75, 0x01, 0x95, 0x05, 0x91, 0x02,
    0x75, 0x03, 0x95, 0x01, 0x91, 0x01,
    0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x15, 0x00, 0x25, 0x65, 0x75, 0x08, 0x95, 0x06, 0x81, 0x00,
    0xC0,
]

let mouseReportDesc: [UInt8] = [
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x03, 0x81, 0x01,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
    0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
    0xC0, 0xC0,
]

func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

// scrcpy control message types (v4.x)
let msgUhidCreate: UInt8 = 12
let msgUhidInput: UInt8 = 13
let msgSetClipboard: UInt8 = 9

// device → Mac messages
let devMsgClipboard: UInt8 = 0
let devMsgAckClipboard: UInt8 = 1
let devMsgUhidOutput: UInt8 = 2

let clipboardMaxBytes = (1 << 18) - 14

func be32(_ v: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) } }

func uhidCreate(id: UInt16, desc: [UInt8]) -> [UInt8] {
    [msgUhidCreate] + be16(Int(id)) + be16(0) + be16(0) + [0] /* empty name */ + be16(desc.count) + desc
}

func uhidInput(id: UInt16, data: [UInt8]) -> [UInt8] {
    [msgUhidInput] + be16(Int(id)) + be16(data.count) + data
}

// MARK: - Phone link (adb + headless scrcpy server)

final class PhoneLink {
    let serial: String
    let phoneWidth: Double
    private let fd: Int32
    private let server: Process
    private let io = DispatchQueue(label: "phonelink.io")
    private var closed = false
    private let lock = NSLock()
    var onClose: (() -> Void)?
    var onClipboard: ((String) -> Void)?   // called on the drain thread

    private init(serial: String, fd: Int32, server: Process, phoneWidth: Double) {
        self.serial = serial; self.fd = fd; self.server = server; self.phoneWidth = phoneWidth
    }

    static func connect(serial: String) -> PhoneLink? {
        let remote = "/data/local/tmp/scrcpy-server.jar"
        let push = run([adb, "-s", serial, "push", serverPath, remote])
        guard push.status == 0 else { log("push failed: \(push.out)"); return nil }

        let scid = UInt32.random(in: 1..<0x7FFF_FFFF)
        let scidHex = String(format: "%08x", scid)
        let fwd = run([adb, "-s", serial, "forward", "tcp:0", "localabstract:scrcpy_\(scidHex)"])
        guard fwd.status == 0, let port = UInt16(fwd.out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            log("adb forward failed: \(fwd.out)"); return nil
        }
        defer { run([adb, "-s", serial, "forward", "--remove", "tcp:\(port)"]) }

        let server = Process()
        server.executableURL = URL(fileURLWithPath: adb)
        server.arguments = [
            "-s", serial, "shell", "CLASSPATH=\(remote)", "app_process", "/", "com.genymobile.scrcpy.Server",
            serverVersion, "scid=\(scidHex)", "log_level=\(config.verbose ? "info" : "warn")",
            "video=false", "audio=false", "control=true", "tunnel_forward=true",
            "send_device_meta=false", "clipboard_autosync=\(config.clipboard)", "cleanup=true",
        ]
        if !config.verbose { server.standardOutput = FileHandle.nullDevice }
        do { try server.run() } catch { log("could not start server: \(error)"); return nil }

        // The adb forward accepts connections before the server listens; the server proves it's
        // really there by sending one dummy byte.
        var fd: Int32 = -1
        for _ in 0..<60 {
            usleep(100_000)
            guard server.isRunning else { log("server exited early"); return nil }
            let s = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if ok {
                var tv = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var b: UInt8 = 0
                if read(s, &b, 1) == 1 {
                    var zero = timeval(tv_sec: 0, tv_usec: 0)
                    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
                    var one: Int32 = 1
                    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    fd = s
                    break
                }
            }
            close(s)
        }
        guard fd >= 0 else { log("could not reach phone server"); server.terminate(); return nil }

        let link = PhoneLink(serial: serial, fd: fd, server: server, phoneWidth: PhoneLink.queryWidth(serial))
        link.send(uhidCreate(id: hidKeyboardID, desc: keyboardReportDesc))
        link.send(uhidCreate(id: hidMouseID, desc: mouseReportDesc))
        link.startDrain()
        return link
    }

    private static func queryWidth(_ serial: String) -> Double {
        // "Physical size: 1080x2280" (+ optional "Override size: ...", which wins)
        let out = run([adb, "-s", serial, "shell", "wm", "size"]).out
        var width = 1080.0
        for line in out.split(separator: "\n") {
            if let r = line.range(of: ": "), let w = Double(line[r.upperBound...].split(separator: "x").first ?? "") {
                width = w
            }
        }
        return width
    }

    // Device messages from the phone: clipboard changes (forwarded), clipboard acks and
    // keyboard LED output (ignored).
    private func startDrain() {
        Thread.detachNewThread { [self] in
            while let type = readExact(1)?.first {
                switch type {
                case devMsgClipboard:
                    guard let lenBytes = readExact(4) else { break }
                    let len = lenBytes.reduce(0) { $0 << 8 | Int($1) }
                    guard let text = readExact(len) else { break }
                    onClipboard?(String(decoding: text, as: UTF8.self))
                    continue
                case devMsgAckClipboard:
                    if readExact(8) != nil { continue }
                case devMsgUhidOutput:
                    if readExact(2) != nil, let sz = readExact(2),
                       readExact(Int(sz[0]) << 8 | Int(sz[1])) != nil { continue }
                default:
                    log("unknown message from phone (\(type)), closing link")
                }
                break
            }
            shutdown()
        }
    }

    private func readExact(_ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n)
        var off = 0
        while off < n {
            let r = buf[off...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if r <= 0 { return nil }
            off += r
        }
        return buf
    }

    func setClipboard(_ text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count <= clipboardMaxBytes else { log("clipboard too large to share (\(bytes.count) bytes)"); return }
        // sequence 0 = no ack wanted; paste = false
        send([msgSetClipboard] + [UInt8](repeating: 0, count: 8) + [0] + be32(bytes.count) + bytes)
    }

    func send(_ bytes: [UInt8]) {
        io.async { [self] in
            var off = 0
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n <= 0 { shutdown(); return }
                off += n
            }
        }
    }

    func shutdown() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR)
        close(fd)
        if server.isRunning { server.terminate() }
        DispatchQueue.main.async { self.onClose?() }
    }
}

// MARK: - macOS keycode → USB HID usage

let hidUsage: [Int64: UInt8] = [
    0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B, 34: 0x0C, 38: 0x0D,
    40: 0x0E, 37: 0x0F, 46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17,
    32: 0x18, 9: 0x19, 13: 0x1A, 7: 0x1B, 16: 0x1C, 6: 0x1D,
    18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25, 25: 0x26, 29: 0x27,
    36: 0x28, 53: 0x29, 51: 0x2A, 48: 0x2B, 49: 0x2C, 27: 0x2D, 24: 0x2E, 33: 0x2F, 30: 0x30, 42: 0x31,
    41: 0x33, 39: 0x34, 50: 0x35, 43: 0x36, 47: 0x37, 44: 0x38, 10: 0x64,
    122: 0x3A, 120: 0x3B, 99: 0x3C, 118: 0x3D, 96: 0x3E, 97: 0x3F, 98: 0x40, 100: 0x41, 101: 0x42,
    109: 0x43, 103: 0x44, 111: 0x45,
    115: 0x4A, 116: 0x4B, 117: 0x4C, 119: 0x4D, 121: 0x4E, 124: 0x4F, 123: 0x50, 125: 0x51, 126: 0x52,
    71: 0x53, 75: 0x54, 67: 0x55, 78: 0x56, 69: 0x57, 76: 0x58,
    83: 0x59, 84: 0x5A, 85: 0x5B, 86: 0x5C, 87: 0x5D, 88: 0x5E, 89: 0x5F, 91: 0x60, 92: 0x61, 82: 0x62, 65: 0x63,
]

let keycodeSpace: Int64 = 49
let keycodeCapsLock: Int64 = 57

// MARK: - Controller

final class Controller {
    var link: PhoneLink?
    var tap: CFMachPort?

    private(set) var onPhone = false
    private var pushAccum = 0.0      // how far the user has pushed against the Mac edge
    private var exitAccum = 0.0      // how far the user has pushed against the phone's near edge
    private var vx = 0.0             // estimated pointer x on the phone
    private var returnY = 0.0
    private var buttons: UInt8 = 0
    private var mods: UInt8 = 0
    private var keys: [UInt8] = []
    private var scrollAccumY = 0.0
    private var scrollAccumX = 0.0
    private var dragStartCount = 0   // drag pasteboard changeCount at mouse-down
    private var dragHandled = false
    private var moveRemX = 0.0       // sub-pixel remainders left over from speed scaling
    private var moveRemY = 0.0

    private let enterThreshold = 30.0
    private let exitThreshold = 40.0

    private func desktopBounds() -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    // MARK: transitions

    func enterPhone(at y: Double) {
        guard let link, !onPhone else { return }
        onPhone = true
        pushAccum = 0; exitAccum = 0
        returnY = y
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())
        // Pin the phone pointer to its near edge so our x estimate starts from a known spot.
        let sweep: Int = config.edge == .right ? -127 : 127
        for _ in 0..<30 { sendMouse(dx: sweep, dy: 0) }
        vx = config.edge == .right ? 0 : link.phoneWidth
        log("→ phone")
    }

    func exitPhone() {
        guard onPhone else { return }
        keys = []; mods = 0; buttons = 0
        sendKeyboard()
        sendMouse(dx: 0, dy: 0)
        onPhone = false
        let b = desktopBounds()
        let x = config.edge == .right ? b.maxX - 40 : b.minX + 40
        CGWarpMouseCursorPosition(CGPoint(x: x, y: returnY))
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        log("← mac")
    }

    // MARK: reports

    private func sendMouse(dx: Int, dy: Int, wheel: Int = 0, hwheel: Int = 0) {
        guard let link else { return }
        var dx = dx, dy = dy
        repeat {
            let sx = max(-127, min(127, dx)), sy = max(-127, min(127, dy))
            dx -= sx; dy -= sy
            let report: [UInt8] = [buttons, UInt8(bitPattern: Int8(sx)), UInt8(bitPattern: Int8(sy)),
                                   UInt8(bitPattern: Int8(max(-127, min(127, wheel)))),
                                   UInt8(bitPattern: Int8(max(-127, min(127, hwheel))))]
            link.send(uhidInput(id: hidMouseID, data: report))
        } while dx != 0 || dy != 0
    }

    private func sendKeyboard() {
        guard let link else { return }
        var report: [UInt8] = [mods, 0, 0, 0, 0, 0, 0, 0]
        for (i, k) in keys.prefix(6).enumerated() { report[2 + i] = k }
        link.send(uhidInput(id: hidKeyboardID, data: report))
    }

    // MARK: event handling

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // ⌃⌥Space toggles in both directions.
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == keycodeSpace,
           event.flags.contains(.maskControl), event.flags.contains(.maskAlternate) {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                if onPhone { exitPhone() } else { enterPhone(at: event.location.y) }
            }
            return nil
        }

        if !onPhone { return handleOnMac(type, event) }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let sx = Double(event.getIntegerValueField(.mouseEventDeltaX)) * config.speed + moveRemX
            let sy = Double(event.getIntegerValueField(.mouseEventDeltaY)) * config.speed + moveRemY
            let dx = Int(sx.rounded(.towardZero)), dy = Int(sy.rounded(.towardZero))
            moveRemX = sx - Double(dx); moveRemY = sy - Double(dy)
            sendMouse(dx: dx, dy: dy)
            trackPhonePointer(Double(dx))

        case .leftMouseDown: buttons |= 0x01; sendMouse(dx: 0, dy: 0)
        case .leftMouseUp: buttons &= ~0x01; sendMouse(dx: 0, dy: 0)
        case .rightMouseDown: buttons |= 0x02; sendMouse(dx: 0, dy: 0)
        case .rightMouseUp: buttons &= ~0x02; sendMouse(dx: 0, dy: 0)
        case .otherMouseDown, .otherMouseUp:
            let n = event.getIntegerValueField(.mouseEventButtonNumber) // 2 middle, 3 back, 4 forward
            if (2...4).contains(n) {
                let bit = UInt8(1 << n)
                if type == .otherMouseDown { buttons |= bit } else { buttons &= ~bit }
                sendMouse(dx: 0, dy: 0)
            }

        case .scrollWheel:
            handleScroll(event)

        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { break } // phone repeats itself
            if let u = hidUsage[event.getIntegerValueField(.keyboardEventKeycode)], !keys.contains(u) {
                keys.append(u)
                if keys.count > 6 { keys.removeFirst() }
                sendKeyboard()
            }
        case .keyUp:
            if let u = hidUsage[event.getIntegerValueField(.keyboardEventKeycode)] {
                keys.removeAll { $0 == u }
                sendKeyboard()
            }
        case .flagsChanged:
            if event.getIntegerValueField(.keyboardEventKeycode) == keycodeCapsLock {
                keys.append(0x39); sendKeyboard()
                keys.removeAll { $0 == 0x39 }; sendKeyboard()
            } else {
                mods = modifierBits(event.flags.rawValue)
                sendKeyboard()
            }
        default:
            return Unmanaged.passUnretained(event)
        }
        return nil // swallow: the Mac doesn't see input while you're on the phone
    }

    private func handleOnMac(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .leftMouseDown {
            dragStartCount = NSPasteboard(name: .drag).changeCount
            dragHandled = false
        }
        guard link != nil, type == .mouseMoved || type == .leftMouseDragged else {
            return Unmanaged.passUnretained(event)
        }
        let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
        let b = desktopBounds()
        let p = event.location
        let atEdge = config.edge == .right ? p.x >= b.maxX - 1 : p.x <= b.minX
        let outward = config.edge == .right ? dx > 0 : dx < 0
        if atEdge && outward {
            pushAccum += abs(dx)
            // Don't hop over mid-drag; a held button would otherwise end up stuck on the Mac.
            if pushAccum >= enterThreshold && type == .mouseMoved { enterPhone(at: p.y) }
            // Dragging files against the edge sends them to the phone instead.
            if pushAccum >= enterThreshold && type == .leftMouseDragged && !dragHandled,
               let link, let files = freshDraggedFiles(), !files.isEmpty {
                dragHandled = true
                cancelDrag()
                sendFilesToPhone(files, link: link)
            }
        } else if !atEdge {
            pushAccum = 0
        }
        return Unmanaged.passUnretained(event)
    }

    // Files being dragged right now (the drag pasteboard changed since this mouse-down).
    private func freshDraggedFiles() -> [URL]? {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragStartCount else { return nil }
        return pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    // Esc cancels a Finder drag, so the original snaps back instead of dropping at the screen edge.
    private func cancelDrag() {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    private func trackPhonePointer(_ dx: Double) {
        guard let link else { return }
        let back = config.edge == .right ? dx < 0 : dx > 0
        let atNearEdge = config.edge == .right ? vx <= 0 : vx >= link.phoneWidth
        if atNearEdge && back && buttons == 0 {
            exitAccum += abs(dx)
            if exitAccum >= exitThreshold { exitPhone(); return }
        } else if !back {
            exitAccum = 0
        }
        vx = max(0, min(link.phoneWidth, vx + dx))
    }

    private func handleScroll(_ event: CGEvent) {
        var wheel = 0, hwheel = 0
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
            // Trackpad / Magic Mouse: accumulate pixel deltas into wheel notches.
            scrollAccumY += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            scrollAccumX += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let step = 12.0
            wheel = Int(scrollAccumY / step); scrollAccumY -= Double(wheel) * step
            hwheel = Int(scrollAccumX / step); scrollAccumX -= Double(hwheel) * step
        } else {
            wheel = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            hwheel = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        }
        if wheel != 0 || hwheel != 0 { sendMouse(dx: 0, dy: 0, wheel: wheel, hwheel: -hwheel) }
    }

    // Device-dependent modifier bits from IOLLEvent.h
    private func modifierBits(_ raw: UInt64) -> UInt8 {
        var m: UInt8 = 0
        if raw & 0x0001 != 0 { m |= 0x01 }                          // left ctrl
        if raw & 0x2000 != 0 { m |= 0x10 }                          // right ctrl
        if raw & 0x0002 != 0 { m |= 0x02 }                          // left shift
        if raw & 0x0004 != 0 { m |= 0x20 }                          // right shift
        if raw & 0x0020 != 0 { m |= 0x04 }                          // left option → alt
        if raw & 0x0040 != 0 { m |= 0x40 }                          // right option → alt
        if raw & 0x0008 != 0 { m |= config.cmdAsCtrl ? 0x01 : 0x08 } // left cmd
        if raw & 0x0010 != 0 { m |= 0x80 }                          // right cmd → meta
        return m
    }
}

let controller = Controller()

// MARK: - Clipboard sync

// Mac → phone: poll the pasteboard (macOS has no change notification).
// Phone → Mac: the phone-side helper pushes every Android clipboard change.
final class ClipboardSync {
    private let pb = NSPasteboard.general
    private var lastChangeCount: Int
    private var lastText: String?   // last text either side knows about; stops ping-pong
    private var timer: Timer?

    init() { lastChangeCount = pb.changeCount }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    // On (re)connect, give the phone whatever the Mac has right now.
    func linkConnected() {
        lastText = nil
        lastChangeCount = -1
        poll()
    }

    private func poll() {
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        // Respect password managers that mark entries concealed/transient (nspasteboard.org).
        let types = pb.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ||
           types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { return }
        guard let text = pb.string(forType: .string), text != lastText, let link = controller.link else { return }
        lastText = text
        link.setClipboard(text)
    }

    func fromPhone(_ text: String) {
        guard text != lastText else { return }
        lastText = text
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
    }
}

let clipboardSync = ClipboardSync()

// MARK: - Device watcher

func pickDevice() -> String? {
    let out = run([adb, "devices"]).out
    let devices = out.split(separator: "\n").dropFirst().compactMap { line -> String? in
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return f.count >= 2 && f[1] == "device" ? String(f[0]) : nil
    }
    // Exact match first; otherwise a partial match, so the USB serial also finds the same phone
    // over wireless debugging (adb-<serial>-xxxx._adb-tls-connect._tcp).
    if let want = config.serial {
        return devices.first { $0 == want } ?? devices.first { $0.contains(want) }
    }
    return devices.first
}

func watchDevices() {
    Thread.detachNewThread {
        var connecting = false
        while true {
            var hasLink = false
            DispatchQueue.main.sync { hasLink = controller.link != nil }
            if !hasLink && !connecting, let serial = pickDevice() {
                connecting = true
                log("device found: \(serial) — starting input link…")
                if let link = PhoneLink.connect(serial: serial) {
                    if config.clipboard {
                        link.onClipboard = { text in DispatchQueue.main.async { clipboardSync.fromPhone(text) } }
                    }
                    link.onClose = {
                        if controller.link === link {
                            controller.exitPhone()
                            controller.link = nil
                            log("disconnected from \(serial)")
                        }
                    }
                    DispatchQueue.main.sync {
                        controller.link = link
                        if config.clipboard { clipboardSync.linkConnected() }
                    }
                    let side = config.edge == .right ? "right" : "left"
                    log("ready — push the cursor off the \(side) edge of your screen, or press ⌃⌥Space")
                }
                connecting = false
            }
            sleep(2)
        }
    }
}

// MARK: - File drop (Mac → phone)

let phoneDropDir = "/storage/emulated/0/Download"
let msgScanFile: UInt8 = 22

func notify(_ text: String) {
    log(text)
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    run(["/usr/bin/osascript", "-e", "display notification \"\(escaped)\" with title \"phonelink\""])
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// Copies dragged files/folders into the phone's Download folder (never overwriting), then asks
// Android to index them so they show up in Files / Gallery right away.
func sendFilesToPhone(_ urls: [URL], link: PhoneLink) {
    DispatchQueue.global(qos: .userInitiated).async { sendFilesToPhoneSync(urls, link: link) }
}

func sendFilesToPhoneSync(_ urls: [URL], link: PhoneLink) {
    do {
        let names = urls.map { $0.lastPathComponent }
        notify(urls.count == 1 ? "Sending \(names[0]) to phone…" : "Sending \(urls.count) items to phone…")
        var sent: [String] = [], failed: [String] = []
        for url in urls {
            let remote = uniqueRemotePath(for: url.lastPathComponent, serial: link.serial)
            let r = run([adb, "-s", link.serial, "push", url.path, remote])
            guard r.status == 0 else { failed.append(url.lastPathComponent); log("push failed: \(r.out)"); continue }
            // adb push keeps the Mac's modification time; stamp "now" so it sorts to the top of
            // Files / Downloads instead of being buried by its original date.
            run([adb, "-s", link.serial, "shell", "find \(shellQuote(remote)) -exec touch {} +"])
            sent.append((remote as NSString).lastPathComponent)
            for path in remoteFiles(local: url, remote: remote) {
                let bytes = Array(path.utf8)
                link.send([msgScanFile] + be32(bytes.count) + bytes)
            }
        }
        if !sent.isEmpty {
            notify(sent.count == 1 ? "\(sent[0]) is in the phone's Download folder" : "\(sent.count) items are in the phone's Download folder")
        }
        if !failed.isEmpty { notify("Could not send: \(failed.joined(separator: ", "))") }
    }
}

func uniqueRemotePath(for name: String, serial: String) -> String {
    let ext = (name as NSString).pathExtension
    let base = (name as NSString).deletingPathExtension
    var candidate = "\(phoneDropDir)/\(name)"
    var n = 1
    while run([adb, "-s", serial, "shell", "test -e \(shellQuote(candidate))"]).status == 0 {
        candidate = "\(phoneDropDir)/\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
        n += 1
    }
    return candidate
}

// Every file the push created on the phone (one for a file, all files inside for a folder).
func remoteFiles(local: URL, remote: String) -> [String] {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir), isDir.boolValue else { return [remote] }
    let files = FileManager.default.enumerator(atPath: local.path)?.compactMap { $0 as? String } ?? []
    return files.filter { rel in
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: local.appendingPathComponent(rel).path, isDirectory: &d) && !d.boolValue
    }.map { "\(remote)/\($0)" }
}

// MARK: - Main

// --send runs alongside a running phonelink (its own short-lived link), so it comes before the lock.
if !config.sendPaths.isEmpty {
    let urls = config.sendPaths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    for u in urls where !FileManager.default.fileExists(atPath: u.path) { print("no such file: \(u.path)"); exit(1) }
    guard let serial = pickDevice(), let link = PhoneLink.connect(serial: serial) else { print("no phone connected"); exit(1) }
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        sendFilesToPhoneSync(urls, link: link)
        done.signal()
    }
    done.wait()
    sleep(1) // let the scan requests reach the phone
    link.shutdown()
    exit(0)
}

// Only one instance at a time: two event taps would fight over the same input.
let lockFD = open("/tmp/phonelink.lock", O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    print("phonelink is already running (only one copy can control the mouse and keyboard)")
    exit(0)
}

if config.selfTest {
    guard let serial = pickDevice(), let link = PhoneLink.connect(serial: serial) else {
        print("self-test: FAILED to connect"); exit(1)
    }
    print("self-test: connected to \(serial), phone width \(Int(link.phoneWidth))px — moving pointer in a square")
    controller.link = link
    for (dx, dy) in [(20, 0), (0, 20), (-20, 0), (0, -20)] {
        for _ in 0..<15 {
            link.send(uhidInput(id: hidMouseID, data: [0, UInt8(bitPattern: Int8(dx)), UInt8(bitPattern: Int8(dy)), 0, 0]))
            usleep(30_000)
        }
    }
    if config.clipboard {
        // A malformed clipboard message makes the phone side drop the link, so staying
        // connected afterwards proves the format is right.
        var closed = false
        link.onClose = { closed = true }
        link.setClipboard("phonelink clipboard test")
        sleep(2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        print(closed ? "self-test: clipboard FAILED (link dropped)" : "self-test: clipboard OK — phone clipboard now says \"phonelink clipboard test\"")
    } else {
        sleep(2)
    }
    print("self-test: done")
    link.shutdown()
    exit(0)
}

if !AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    log("""
    waiting for Accessibility permission —
    System Settings → Privacy & Security → Accessibility → enable phonelink
    (or your terminal app, if you started it from a terminal)
    """)
    while !AXIsProcessTrusted() { sleep(3) }
    log("Accessibility permission granted")
}

let eventTypes: [CGEventType] = [
    .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    .scrollWheel, .keyDown, .keyUp, .flagsChanged,
]
let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
    callback: { _, type, event, _ in controller.handle(type, event) }, userInfo: nil)
else {
    print("could not create event tap — check Accessibility permission for your terminal app")
    exit(1)
}
controller.tap = tap
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// Always give the Mac its cursor back on Ctrl-C / kill.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler {
        controller.exitPhone()
        controller.link?.shutdown()
        exit(0)
    }
    s.resume()
    signalSources.append(s)
}

log("phonelink \(phonelinkVersion) started (scrcpy-server \(serverVersion), phone on the \(config.edge.rawValue)) — waiting for a device…")
if config.clipboard { clipboardSync.start() }
watchDevices()
CFRunLoopRun()
