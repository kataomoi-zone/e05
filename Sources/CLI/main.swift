import Darwin
import Foundation

// MARK: - Entry point

let args = CommandLine.arguments
guard args.count >= 2 else {
  printUsage(to: FileHandle.standardError)
  exit(2)
}

let cmd = args[1]
let rest = Array(args.dropFirst(2))

switch cmd {
case "open":
  runOpen(rest)
case "action":
  runAction(rest)
case "switch-workspace":
  runSwitchWorkspace(rest)
case "notify":
  runNotify(rest)
case "help", "--help", "-h":
  printUsage(to: FileHandle.standardOutput)
  exit(0)
default:
  errln("e05: unknown subcommand '\(cmd)'")
  printUsage(to: FileHandle.standardError)
  exit(2)
}

// MARK: - Subcommands

/// Translate a host reply into a process exit so shell scripts can
/// branch on `host responded ok=false` (exit 1) versus `host
/// unreachable / transport blew up` (exit 3) without parsing stderr.
func exitFromReply(_ reply: Reply, prefix: String) -> Never {
  switch reply {
  case .ok:
    exit(0)
  case .hostError(let message):
    errln("\(prefix): \(message)")
    exit(1)
  case .transportError(let message):
    errln("\(prefix): \(message)")
    exit(3)
  }
}

func runOpen(_ args: [String]) {
  guard let target = args.first else {
    errln("e05 open: missing argument")
    exit(2)
  }
  let urlString = normalizeOpenArgument(target)
  exitFromReply(sendRequest(["op": "open", "url": urlString]), prefix: "e05 open")
}

func runAction(_ args: [String]) {
  guard let id = args.first else {
    errln("e05 action: missing action id (e.g. focus_right, new_browser_pane)")
    exit(2)
  }
  exitFromReply(sendRequest(["op": "action", "id": id]), prefix: "e05 action")
}

func runSwitchWorkspace(_ args: [String]) {
  guard let raw = args.first, let index = Int(raw), index >= 0 else {
    errln("e05 switch-workspace: missing or invalid <index> (0-based)")
    exit(2)
  }
  exitFromReply(
    sendRequest(["op": "switch-workspace", "index": index]),
    prefix: "e05 switch-workspace")
}

func runNotify(_ args: [String]) {
  // Join positional args so `e05 notify Hello world` and
  // `e05 notify "Hello world"` reach the host identically.
  let message = args.joined(separator: " ")
  guard !message.isEmpty else {
    errln("e05 notify: missing <message>")
    exit(2)
  }
  exitFromReply(sendRequest(["op": "notify", "message": message]), prefix: "e05 notify")
}

/// Bare paths become `file://` URLs so the host can route them through
/// `PaneAddress.finder`; URLs with a scheme pass through unchanged.
func normalizeOpenArgument(_ arg: String) -> String {
  if arg.contains("://") { return arg }
  let expanded = (arg as NSString).expandingTildeInPath
  let absolute: String
  if expanded.hasPrefix("/") {
    absolute = expanded
  } else {
    absolute = (FileManager.default.currentDirectoryPath as NSString)
      .appendingPathComponent(expanded)
  }
  let standardized = (absolute as NSString).standardizingPath
  return URL(fileURLWithPath: standardized).absoluteString
}

// MARK: - Socket transport

enum Reply {
  /// Host accepted and replied `ok=true`. Maps to exit 0.
  case ok
  /// Host replied `ok=false` with an error string. Maps to exit 1 —
  /// shell scripts can retry after fixing the request.
  case hostError(String)
  /// Connection / write / read / decode failed before the host could
  /// reply. Maps to exit 3 — shell scripts can use this to recover
  /// "host is down" separately from "request was rejected".
  case transportError(String)
}

func sendRequest(_ payload: [String: Any]) -> Reply {
  let socketPath = resolveSocketPath()
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else {
    return .transportError("socket() failed errno=\(errno)")
  }
  defer { close(fd) }

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
  guard socketPath.utf8CString.count <= maxPath else {
    return .transportError("socket path too long: \(socketPath)")
  }
  _ = socketPath.withCString { src in
    withUnsafeMutablePointer(to: &addr.sun_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: maxPath) {
        strlcpy($0, src, maxPath)
      }
    }
  }

  let connectResult = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard connectResult == 0 else {
    return .transportError("cannot connect to \(socketPath) (is e05 running?)")
  }

  guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
    return .transportError("failed to encode request")
  }
  var request = body
  request.append(UInt8(ascii: "\n"))
  let written = request.withUnsafeBytes { ptr in
    Darwin.write(fd, ptr.baseAddress, ptr.count)
  }
  guard written == request.count else {
    return .transportError("write failed errno=\(errno)")
  }

  var response = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let n = buffer.withUnsafeMutableBufferPointer { ptr in
      Darwin.read(fd, ptr.baseAddress, ptr.count)
    }
    if n < 0 {
      if errno == EINTR { continue }
      return .transportError("read failed errno=\(errno)")
    }
    if n == 0 { break }
    response.append(buffer, count: n)
  }

  guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
    let raw = String(decoding: response, as: UTF8.self)
    return .transportError("invalid response: \(raw)")
  }
  if let ok = json["ok"] as? Bool, ok {
    return .ok
  }
  let message = (json["error"] as? String) ?? "host returned ok=false without error message"
  return .hostError(message)
}

// MARK: - Socket-path discovery

/// `E05_SOCKET` env wins; otherwise locate the surrounding `.app`
/// bundle and read its `CFBundleIdentifier` so the CLI bundled into
/// `e05[DEV].app` talks to the dev host and the release variant talks
/// to the release host. A symlinked `e05` (e.g. `/usr/local/bin/e05`)
/// is resolved before the walk so the bundle is reachable.
func resolveSocketPath() -> String {
  if let env = ProcessInfo.processInfo.environment["E05_SOCKET"], !env.isEmpty {
    return env
  }
  let bundleId = locateBundleIdentifier() ?? "org.kawarimidoll.e05"
  let home = FileManager.default.homeDirectoryForCurrentUser
  return
    home
    .appendingPathComponent("Library/Application Support/\(bundleId)/control.sock")
    .path
}

func locateBundleIdentifier() -> String? {
  // PATH lookups (`which e05` style invocations) leave `argv[0]` as the
  // bare program name with no directory, so `realpath(argv[0])` returns
  // nil and the bundle walk dies before it starts. `_NSGetExecutablePath`
  // hands back the real on-disk path of this process regardless of how
  // the loader found it.
  var bufSize: UInt32 = 4096
  var buf = [CChar](repeating: 0, count: Int(bufSize))
  guard _NSGetExecutablePath(&buf, &bufSize) == 0 else { return nil }
  let exePath = String(cString: buf)
  guard let resolved = realpath(exePath, nil) else { return nil }
  defer { free(resolved) }
  var url = URL(fileURLWithPath: String(cString: resolved))
  // Walk up at most 8 levels looking for an `*.app` ancestor whose
  // `Contents/Info.plist` carries the bundle id we need.
  for _ in 0..<8 {
    url = url.deletingLastPathComponent()
    if url.pathExtension == "app" {
      let plistURL = url.appendingPathComponent("Contents/Info.plist")
      if let data = try? Data(contentsOf: plistURL),
        let plist = try? PropertyListSerialization.propertyList(
          from: data, format: nil) as? [String: Any],
        let identifier = plist["CFBundleIdentifier"] as? String
      {
        return identifier
      }
      return nil
    }
    if url.path == "/" { return nil }
  }
  return nil
}

// MARK: - Output helpers

func errln(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printUsage(to handle: FileHandle) {
  let text = """
    Usage: e05 <subcommand> [args...]

    Subcommands:
      open <url-or-path>    Open URL or filesystem path as a new pane
      action <id>           Run a registered palette action by id
      switch-workspace <i>  Switch focus to workspace at zero-based index
      notify <message...>   Post a toast in the current workspace
      help                  Show this message

    Environment:
      E05_SOCKET            Override the control-socket path
                            (default: derived from the hosting .app
                            bundle's CFBundleIdentifier)

    """
  handle.write(Data(text.utf8))
}
