// unsleep — CLI for the UnSleep menu bar app.
//
// Thin client: all state (caffeinate + pmset + timers) is owned by
// UnSleep.app, which this CLI talks to over a unix socket. Mutating commands
// auto-launch the app if it isn't running.
//
// NOTE: all logic lives in functions and runs via runMain() — keep it that
// way. Top-level script-mode variables are secretly globals, and Swift 6.2.3
// miscompiled them under -O (spurious "Index out of range" /
// "unsafelyUnwrapped of nil" traps). See also build.sh (-Onone).

import Foundation

let socketPath = NSString(string: "~/Library/Application Support/UnSleep/ctl.sock").expandingTildeInPath
let appPath = NSString(string: "~/Applications/UnSleep.app").expandingTildeInPath

let usage = """
usage:
  unsleep on [--from HH:MM] [--until HH:MM] [--for <duration>]
  unsleep off | toggle
  unsleep status [--json]

  --from defaults to now; without --until/--for it stays on indefinitely.
  durations: 90 (minutes), 45m, 2h, 1h30m
  times: 24-hour HH:MM. A past time rolls to tomorrow; overnight
  --from/--until windows (e.g. --from 22:00 --until 06:00) are fine.

examples:
  unsleep on --for 2h                # awake for 2 hours
  unsleep on --until 17:30           # awake until 5:30 PM
  unsleep on --from 13:00 --until 15:00   # awake during a window
  unsleep off                        # restore sleep, cancel any window
"""

func die(_ msg: String) -> Never {
  FileHandle.standardError.write(Data(("unsleep: " + msg + "\n").utf8))
  exit(1)
}

// MARK: - Parsing

func parseDuration(_ s: String) -> TimeInterval? {
  let lower = s.lowercased()
  if let minutes = Int(lower) { return TimeInterval(minutes * 60) }
  var total = 0
  var num = ""
  for ch in lower {
    if ch.isNumber {
      num.append(ch)
    } else if ch == "h" || ch == "m" || ch == "s" {
      guard let n = Int(num) else { return nil }
      total += n * (ch == "h" ? 3600 : ch == "m" ? 60 : 1)
      num = ""
    } else {
      return nil
    }
  }
  if !num.isEmpty {
    guard let n = Int(num) else { return nil }
    total += n * 60
  }
  return total > 0 ? TimeInterval(total) : nil
}

func parseHM(_ s: String) -> (Int, Int)? {
  let parts = s.split(separator: ":").map(String.init)
  guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
    (0...23).contains(h), (0...59).contains(m)
  else { return nil }
  return (h, m)
}

func dateAt(_ hm: (Int, Int), sameDayAs now: Date) -> Date {
  let cal = Calendar.current
  var comps = cal.dateComponents([.year, .month, .day], from: now)
  comps.hour = hm.0; comps.minute = hm.1; comps.second = 0
  return cal.date(from: comps)!
}

/// Next occurrence of HH:MM (today, or tomorrow if already past).
func nextOccurrence(_ hm: (Int, Int), now: Date) -> Date {
  var date = dateAt(hm, sameDayAs: now)
  if date <= now { date = Calendar.current.date(byAdding: .day, value: 1, to: date)! }
  return date
}

/// Next occurrence of a [from, until] window (mirrors the app's logic).
func windowDates(fromHM: (Int, Int), toHM: (Int, Int), now: Date) -> (Date, Date) {
  let cal = Calendar.current
  var from = dateAt(fromHM, sameDayAs: now)
  var to = dateAt(toHM, sameDayAs: now)
  if to <= from { to = cal.date(byAdding: .day, value: 1, to: to)! }
  if to <= now {
    from = cal.date(byAdding: .day, value: 1, to: from)!
    to = cal.date(byAdding: .day, value: 1, to: to)!
  }
  return (from, to)
}

// MARK: - Socket client

func connectToApp() -> Int32? {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  socketPath.withCString { cs in
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      _ = strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), cs, buf.count - 1)
    }
  }
  let result = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  if result != 0 { close(fd); return nil }
  // Generous read timeout: the app may be waiting on an admin password prompt.
  var tv = timeval(tv_sec: 300, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  return fd
}

func launchAppAndConnect() -> Int32? {
  guard FileManager.default.fileExists(atPath: appPath) else { return nil }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  // Open by PATH, not bundle id: freshly built apps aren't registered with
  // LaunchServices yet, so `open -b` fails until the first path-based open.
  p.arguments = ["-g", appPath]
  do { try p.run() } catch { return nil }
  p.waitUntilExit()
  guard p.terminationStatus == 0 else { return nil }
  for _ in 0..<25 {  // up to ~5s
    usleep(200_000)
    if let fd = connectToApp() { return fd }
  }
  return nil
}

func sendCommand(_ command: String, launchIfNeeded: Bool) -> [String: Any]? {
  var maybeFd = connectToApp()
  if maybeFd == nil, launchIfNeeded { maybeFd = launchAppAndConnect() }
  guard let fd = maybeFd else { return nil }
  defer { close(fd) }

  let out = Array((command + "\n").utf8)
  guard out.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == out.count else { return nil }

  var buf = [UInt8](repeating: 0, count: 4096)
  var data = [UInt8]()
  while !data.contains(UInt8(ascii: "\n")) {
    let n = read(fd, &buf, buf.count)
    if n <= 0 { break }
    data.append(contentsOf: buf[0..<n])
  }
  guard !data.isEmpty,
    let obj = try? JSONSerialization.jsonObject(with: Data(data)) as? [String: Any]
  else { return nil }
  return obj
}

// MARK: - Output

func shortTime(_ epoch: Double) -> String {
  let f = DateFormatter()
  f.timeStyle = .short
  f.dateStyle = .none
  return f.string(from: Date(timeIntervalSince1970: epoch))
}

func describe(_ obj: [String: Any]) -> String {
  let active = obj["active"] as? Bool ?? false
  if active {
    guard let until = obj["until"] as? Double else { return "on" }
    let mins = max(0, Int((until - Date().timeIntervalSince1970) / 60))
    return "on until \(shortTime(until)) (\(mins)m left)"
  }
  if let from = obj["from"] as? Double {
    let end = (obj["until"] as? Double).map { " until \(shortTime($0))" } ?? ""
    return "off — starts \(shortTime(from))\(end)"
  }
  return "off"
}

func finish(_ obj: [String: Any]?, json: Bool, notRunningIsOff: Bool) -> Never {
  guard let obj else {
    if notRunningIsOff {
      print(json
        ? #"{"ok":true,"running":false,"active":false,"from":null,"until":null}"#
        : "off (app not running)")
      exit(0)
    }
    die("could not reach UnSleep.app (is it built? run ./install.sh from the repo)")
  }
  if json {
    let data = try! JSONSerialization.data(withJSONObject: obj)
    print(String(data: data, encoding: .utf8)!)
  } else {
    print(describe(obj))
    if let err = obj["error"] as? String {
      FileHandle.standardError.write(Data(("unsleep: " + err + "\n").utf8))
    }
  }
  exit((obj["ok"] as? Bool ?? false) ? 0 : 1)
}

// MARK: - Commands

func handleOn(_ opts: [String], json: Bool) -> Never {
  var fromHM: (Int, Int)?
  var untilHM: (Int, Int)?
  var forDuration: TimeInterval?

  var i = 0
  while i < opts.count {
    switch opts[i] {
    case "--from":
      guard i + 1 < opts.count, let hm = parseHM(opts[i + 1]) else {
        die("bad --from time (use 24-hour HH:MM)")
      }
      fromHM = hm
      i += 2
    case "--until":
      guard i + 1 < opts.count, let hm = parseHM(opts[i + 1]) else {
        die("bad --until time (use 24-hour HH:MM)")
      }
      untilHM = hm
      i += 2
    case "--for":
      guard i + 1 < opts.count, let dur = parseDuration(opts[i + 1]) else {
        die("bad --for duration (try: 90, 45m, 2h, 1h30m)")
      }
      forDuration = dur
      i += 2
    default:
      die("unknown option: \(opts[i])\n\(usage)")
    }
  }
  if untilHM != nil, forDuration != nil {
    die("--until and --for are mutually exclusive")
  }

  // "-" means: let the app use its own clock (from = now / until = never).
  let now = Date()
  var fromArg = "-"
  var untilArg = "-"

  func epoch(_ d: Date) -> String { String(Int(d.timeIntervalSince1970)) }

  if let f = fromHM {
    if let u = untilHM {
      let (from, until) = windowDates(fromHM: f, toHM: u, now: now)
      fromArg = epoch(from)
      untilArg = epoch(until)
    } else {
      let from = nextOccurrence(f, now: now)
      fromArg = epoch(from)
      if let d = forDuration { untilArg = epoch(from.addingTimeInterval(d)) }
    }
  } else if let u = untilHM {
    untilArg = epoch(nextOccurrence(u, now: now))
  } else if let d = forDuration {
    untilArg = epoch(now.addingTimeInterval(d))
  }

  finish(sendCommand("on \(fromArg) \(untilArg)", launchIfNeeded: true),
         json: json, notRunningIsOff: false)
}

func runMain() -> Never {
  signal(SIGPIPE, SIG_IGN)
  var args = Array(CommandLine.arguments.dropFirst())
  let json = args.contains("--json")
  args.removeAll { $0 == "--json" }

  guard let cmd = args.first else {
    print(usage)
    exit(2)
  }

  switch cmd {
  case "on":
    handleOn(Array(args.dropFirst()), json: json)
  case "off":
    finish(sendCommand("off", launchIfNeeded: false), json: json, notRunningIsOff: true)
  case "toggle":
    finish(sendCommand("toggle", launchIfNeeded: true), json: json, notRunningIsOff: false)
  case "status":
    finish(sendCommand("status", launchIfNeeded: false), json: json, notRunningIsOff: true)
  case "help", "-h", "--help":
    print(usage)
    exit(0)
  default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
  }
}

runMain()
