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
case "help", "--help", "-h":
  printUsage(to: FileHandle.standardOutput)
  exit(0)
default:
  errln("e05: unknown subcommand '\(cmd)'")
  printUsage(to: FileHandle.standardError)
  exit(2)
}

// MARK: - Subcommands

func runOpen(_ args: [String]) {
  guard let target = args.first else {
    errln("e05 open: missing argument")
    exit(2)
  }
  let urlString = normalizeOpenArgument(target)
  let response = sendRequest(["op": "open", "url": urlString])
  switch response {
  case .ok:
    exit(0)
  case .err(let message):
    errln("e05 open: \(message)")
    exit(1)
  }
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
  case ok
  case err(String)
}

func sendRequest(_ payload: [String: String]) -> Reply {
  let socketPath = resolveSocketPath()
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else {
    return .err("socket() failed errno=\(errno)")
  }
  defer { close(fd) }

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
  guard socketPath.utf8CString.count <= maxPath else {
    return .err("socket path too long: \(socketPath)")
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
    return .err("cannot connect to \(socketPath) (is e05 running?)")
  }

  guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
    return .err("failed to encode request")
  }
  var request = body
  request.append(UInt8(ascii: "\n"))
  let written = request.withUnsafeBytes { ptr in
    Darwin.write(fd, ptr.baseAddress, ptr.count)
  }
  guard written == request.count else {
    return .err("write failed errno=\(errno)")
  }

  var response = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let n = buffer.withUnsafeMutableBufferPointer { ptr in
      Darwin.read(fd, ptr.baseAddress, ptr.count)
    }
    if n < 0 {
      if errno == EINTR { continue }
      return .err("read failed errno=\(errno)")
    }
    if n == 0 { break }
    response.append(buffer, count: n)
  }

  guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
    let raw = String(decoding: response, as: UTF8.self)
    return .err("invalid response: \(raw)")
  }
  if let ok = json["ok"] as? Bool, ok {
    return .ok
  }
  let message = (json["error"] as? String) ?? "host returned ok=false without error message"
  return .err(message)
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
      help                  Show this message

    Environment:
      E05_SOCKET            Override the control-socket path
                            (default: derived from the hosting .app
                            bundle's CFBundleIdentifier)

    """
  handle.write(Data(text.utf8))
}
