// UnSleep — menu bar app that prevents sleep (including lid-close sleep).
//
//   on:  pmset -b sleep 0; pmset -b disablesleep 1; caffeinate -disu
//   off: kill caffeinate; pmset -b sleep 0; pmset -b disablesleep 0
//
// State is one optional session (from, until?):
//   session == nil            → off
//   session.from <= now       → awake now (until `until`, or indefinitely)
//   session.from > now        → pending: turns on at `from`
//
// The app is the single owner of state. A unix-socket control server at
// ~/Library/Application Support/UnSleep/ctl.sock serves the `unsleep` CLI,
// so CLI and menu bar always stay in sync.
//
// pmset needs root: tries `sudo -n` first (see install-sudoers.sh), otherwise
// falls back to a macOS admin password prompt.

import AppKit

// MARK: - Process helper

@discardableResult
func runTool(_ path: String, _ args: [String]) -> Bool {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: path)
  p.arguments = args
  p.standardOutput = FileHandle.nullDevice
  p.standardError = FileHandle.nullDevice
  do { try p.run() } catch { return false }
  p.waitUntilExit()
  return p.terminationStatus == 0
}

// MARK: - Password-free mode (sudoers rule)

enum PasswordFree {
  static let rulePath = "/etc/sudoers.d/unsleep"
  private static let pmsetCommands = [
    ["-b", "sleep", "0"],
    ["-b", "disablesleep", "1"],
    ["-b", "disablesleep", "0"],
  ]

  /// True when all three pmset commands are allowed without authentication.
  static func isInstalled() -> Bool {
    pmsetCommands.allSatisfy { isAllowedWithoutPassword($0) }
  }

  private static func isAllowedWithoutPassword(_ pmsetArgs: [String]) -> Bool {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = ["-n", "-ll", "/usr/bin/pmset"] + pmsetArgs
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    let listing = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return false }
    return String(decoding: listing, as: UTF8.self).contains("!authenticate")
  }

  /// Installs the rule via one native admin-password dialog.
  /// Validates with visudo before installing; installs root:wheel 0440.
  static func install() -> Bool {
    let user = NSUserName()
    let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -b sleep 0, "
      + "/usr/bin/pmset -b disablesleep 1, /usr/bin/pmset -b disablesleep 0\n"
    let tmp = NSTemporaryDirectory() + "unsleep-sudoers-\(getpid())"
    do { try rule.write(toFile: tmp, atomically: true, encoding: .utf8) } catch { return false }
    defer { unlink(tmp) }
    let shell = "/usr/sbin/visudo -cf '\(tmp)' && "
      + "/usr/bin/install -m 0440 -o root -g wheel '\(tmp)' \(rulePath)"
    return runTool("/usr/bin/osascript", ["-e", "do shell script \"\(shell)\" with administrator privileges"])
  }
}

// MARK: - Controller (owns all state; serialized on its own queue)

final class Controller {
  struct Snapshot {
    var active = false
    var from: Date?
    var until: Date?
  }

  private let queue = DispatchQueue(label: "unsleep.state")
  private var session: (from: Date, until: Date?)?
  private var physicallyOn = false
  private var caffeinate: Process?
  private var startTimer: DispatchSourceTimer?
  private var offTimer: DispatchSourceTimer?
  private var checkInTimer: DispatchSourceTimer?
  private var activeSince: Date?
  private var lastError: String?

  /// Called (on the controller queue) after every state change.
  var onChange: ((Snapshot) -> Void)?
  /// Called (on the controller queue) for async failures (timer-fired etc).
  var onError: ((String) -> Void)?
  /// Called (on the controller queue) when a session has been continuously
  /// awake for `checkInInterval` — asks the user whether that's still intended.
  var onCheckIn: ((Date) -> Void)?

  /// 20h by default; override for testing/tuning:
  ///   defaults write com.patsissons.UnSleep CheckInHours -float 0.01
  private var checkInInterval: TimeInterval {
    let hours = UserDefaults.standard.double(forKey: "CheckInHours")
    return (hours > 0 ? hours : 20) * 3600
  }

  /// User confirmed the long-running session — re-arm for another interval.
  func extendCheckIn() {
    queue.sync { if physicallyOn { armCheckInTimer() } }
  }

  // MARK: Public API — thread-safe, blocking (pmset may prompt for a password)

  func currentStatus() -> Snapshot { queue.sync { snapshot() } }

  /// from == nil means "now"; until == nil means "indefinitely".
  func set(from: Date?, until: Date?) -> (Snapshot, String?) {
    queue.sync { (_set(from: from ?? Date(), until: until), lastError) }
  }

  func off() -> (Snapshot, String?) {
    queue.sync { (_off(), lastError) }
  }

  func toggle() -> (Snapshot, String?) {
    queue.sync { (physicallyOn ? _off() : _set(from: Date(), until: nil), lastError) }
  }

  func shutdown() {
    queue.sync {
      cancelTimers()
      session = nil
      _ = ensureOff()
    }
  }

  // MARK: Internals — must run on `queue`

  private func snapshot() -> Snapshot {
    Snapshot(active: physicallyOn, from: session?.from, until: session?.until)
  }

  private func changed() { onChange?(snapshot()) }

  private func _set(from: Date, until: Date?) -> Snapshot {
    lastError = nil
    let now = Date()
    if let until {
      guard until > now else {
        lastError = "end time has already passed"
        return snapshot()
      }
      guard until > from else {
        lastError = "end time must be after start time"
        return snapshot()
      }
    }
    cancelTimers()
    if from <= now {
      guard ensureOn() else {
        session = nil
        changed()
        return snapshot()
      }
      session = (from, until)
      if let until { armOffTimer(at: until) }
    } else {
      _ = ensureOff()  // pending window: stay asleep-able until it opens
      session = (from, until)
      armStartTimer(at: from)
    }
    changed()
    return snapshot()
  }

  private func _off() -> Snapshot {
    lastError = nil
    cancelTimers()
    session = nil
    _ = ensureOff()
    changed()
    return snapshot()
  }

  // MARK: Timers

  private func cancelTimers() {
    startTimer?.cancel(); startTimer = nil
    offTimer?.cancel(); offTimer = nil
  }

  private func armStartTimer(at date: Date) {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(wallDeadline: .now() + date.timeIntervalSinceNow)
    timer.setEventHandler { [weak self] in
      guard let self, let session = self.session, !self.physicallyOn else { return }
      self.lastError = nil
      if self.ensureOn() {
        if let until = session.until { self.armOffTimer(at: until) }
      } else {
        self.session = nil
        self.onError?("Scheduled start failed: \(self.lastError ?? "pmset failed")")
      }
      self.changed()
    }
    timer.resume()
    startTimer = timer
  }

  private func armOffTimer(at date: Date) {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(wallDeadline: .now() + date.timeIntervalSinceNow)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      _ = self._off()
      if let err = self.lastError { self.onError?(err) }
    }
    timer.resume()
    offTimer = timer
  }

  // MARK: Physical state (pmset + caffeinate)

  private func ensureOn() -> Bool {
    if physicallyOn { return true }
    guard setSleepDisabled(true) else {
      lastError = "pmset failed (authorization denied or cancelled)"
      return false
    }
    guard startCaffeinate() else {
      _ = setSleepDisabled(false)
      lastError = "failed to start caffeinate"
      return false
    }
    physicallyOn = true
    activeSince = Date()
    armCheckInTimer()
    return true
  }

  /// Clears the continuous-awake anchor and check-in timer. Call whenever
  /// physicallyOn transitions to false.
  private func clearPhysicalTracking() {
    activeSince = nil
    checkInTimer?.cancel()
    checkInTimer = nil
  }

  private func armCheckInTimer() {
    checkInTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(wallDeadline: .now() + checkInInterval)
    timer.setEventHandler { [weak self] in
      guard let self, self.physicallyOn, let since = self.activeSince else { return }
      self.onCheckIn?(since)
    }
    timer.resume()
    checkInTimer = timer
  }

  private func ensureOff() -> Bool {
    if !physicallyOn { return true }
    stopCaffeinate()
    physicallyOn = false
    clearPhysicalTracking()
    guard setSleepDisabled(false) else {
      lastError = "pmset failed to restore sleep — run: sudo pmset -b disablesleep 0"
      return false
    }
    return true
  }

  private func startCaffeinate() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    p.arguments = ["-disu"]
    p.terminationHandler = { [weak self] proc in
      guard let self else { return }
      self.queue.async {
        // Unexpected death (not initiated by stopCaffeinate) — restore sleep.
        guard self.physicallyOn, self.caffeinate === proc else { return }
        self.caffeinate = nil
        self.physicallyOn = false
        self.clearPhysicalTracking()
        self.cancelTimers()
        self.session = nil
        _ = self.setSleepDisabled(false)
        self.changed()
        self.onError?("caffeinate exited unexpectedly; sleep settings restored")
      }
    }
    do { try p.run() } catch { return false }
    caffeinate = p
    return true
  }

  private func stopCaffeinate() {
    guard let p = caffeinate else { return }
    caffeinate = nil  // detach first so terminationHandler ignores this
    if p.isRunning {
      p.terminate()
      p.waitUntilExit()
    }
  }

  /// Applies: pmset -b sleep 0 && pmset -b disablesleep {1|0}
  private func setSleepDisabled(_ disabled: Bool) -> Bool {
    let flag = disabled ? "1" : "0"
    // Fast path: passwordless sudo (requires /etc/sudoers.d/unsleep rule).
    if sudoNoPrompt(["-b", "sleep", "0"]) && sudoNoPrompt(["-b", "disablesleep", flag]) {
      return true
    }
    // Fallback: native admin password prompt (one prompt for both commands).
    let shell = "/usr/bin/pmset -b sleep 0 && /usr/bin/pmset -b disablesleep \(flag)"
    return runTool("/usr/bin/osascript", ["-e", "do shell script \"\(shell)\" with administrator privileges"])
  }

  private func sudoNoPrompt(_ pmsetArgs: [String]) -> Bool {
    runTool("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + pmsetArgs)
  }
}

// MARK: - Status JSON

func statusJSON(_ s: Controller.Snapshot, ok: Bool = true, error: String? = nil) -> String {
  var dict: [String: Any] = ["ok": ok, "running": true, "active": s.active]
  dict["from"] = s.from.map { Int($0.timeIntervalSince1970) } ?? NSNull()
  dict["until"] = s.until.map { Int($0.timeIntervalSince1970) } ?? NSNull()
  if let error { dict["error"] = error }
  let data = try! JSONSerialization.data(withJSONObject: dict)
  return String(data: data, encoding: .utf8)!
}

// MARK: - Control socket server

final class SocketServer {
  static let path = NSString(string: "~/Library/Application Support/UnSleep/ctl.sock").expandingTildeInPath

  private let controller: Controller
  private var fd: Int32 = -1

  init(controller: Controller) { self.controller = controller }

  func start() {
    let dir = (SocketServer.path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    unlink(SocketServer.path)

    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    SocketServer.path.withCString { cs in
      withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        _ = strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), cs, buf.count - 1)
      }
    }
    let bindResult = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0, listen(fd, 8) == 0 else { close(fd); fd = -1; return }
    chmod(SocketServer.path, 0o600)

    DispatchQueue.global().async { [self] in
      while true {
        let cfd = accept(fd, nil, nil)
        if cfd < 0 {
          if errno == EBADF { break }  // socket closed on shutdown
          continue
        }
        DispatchQueue.global().async { self.handle(cfd) }
      }
    }
  }

  func stop() {
    if fd >= 0 { close(fd); fd = -1 }
    unlink(SocketServer.path)
  }

  private func handle(_ cfd: Int32) {
    defer { close(cfd) }
    var buf = [UInt8](repeating: 0, count: 1024)
    var data = [UInt8]()
    while data.count < 1024, !data.contains(UInt8(ascii: "\n")) {
      let n = read(cfd, &buf, buf.count)
      if n <= 0 { break }
      data.append(contentsOf: buf[0..<n])
    }
    guard let line = String(bytes: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty
    else { return }

    let reply = process(line)
    let out = Array((reply + "\n").utf8)
    _ = out.withUnsafeBytes { write(cfd, $0.baseAddress, $0.count) }
  }

  private func process(_ line: String) -> String {
    let parts = line.split(separator: " ").map(String.init)
    func fail(_ msg: String) -> String {
      statusJSON(controller.currentStatus(), ok: false, error: msg)
    }
    guard let cmd = parts.first else { return fail("empty command") }

    switch cmd {
    case "status":
      return statusJSON(controller.currentStatus())
    case "on":
      // on <from-epoch|-> <until-epoch|->
      guard parts.count == 3 else { return fail("usage: on <from|-> <until|->") }
      var from: Date?
      var until: Date?
      if parts[1] != "-" {
        guard let e = Double(parts[1]) else { return fail("bad from timestamp") }
        from = Date(timeIntervalSince1970: e)
      }
      if parts[2] != "-" {
        guard let e = Double(parts[2]) else { return fail("bad until timestamp") }
        until = Date(timeIntervalSince1970: e)
      }
      let (s, err) = controller.set(from: from, until: until)
      return statusJSON(s, ok: err == nil, error: err)
    case "off":
      let (s, err) = controller.off()
      return statusJSON(s, ok: err == nil, error: err)
    case "toggle":
      let (s, err) = controller.toggle()
      return statusJSON(s, ok: err == nil, error: err)
    default:
      return fail("unknown command: \(cmd)")
    }
  }
}

// MARK: - Window helper

/// Next occurrence of a [from, until] clock-time window. Overnight windows
/// (until <= from) roll `until` into the next day; fully-past windows roll both.
func windowDates(fromHM: (Int, Int), toHM: (Int, Int), now: Date = Date()) -> (Date, Date) {
  let cal = Calendar.current
  var comps = cal.dateComponents([.year, .month, .day], from: now)
  comps.hour = fromHM.0; comps.minute = fromHM.1; comps.second = 0
  var from = cal.date(from: comps)!
  comps.hour = toHM.0; comps.minute = toHM.1
  var to = cal.date(from: comps)!
  if to <= from { to = cal.date(byAdding: .day, value: 1, to: to)! }
  if to <= now {
    from = cal.date(byAdding: .day, value: 1, to: from)!
    to = cal.date(byAdding: .day, value: 1, to: to)!
  }
  return (from, to)
}

// MARK: - App delegate / UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let controller = Controller()
  private var server: SocketServer!
  private var statusItem: NSStatusItem!
  private var statusLine: NSMenuItem!
  private var toggleItem: NSMenuItem!
  private var cancelScheduleItem: NSMenuItem!
  private var setupItem: NSMenuItem!
  private var sigtermSource: DispatchSourceSignal?
  private var uiStatus = Controller.Snapshot()

  private let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f
  }()

  func applicationDidFinishLaunching(_ note: Notification) {
    signal(SIGPIPE, SIG_IGN)

    // Handle SIGTERM (pkill, logout edge cases) gracefully so sleep settings
    // are restored via the normal applicationWillTerminate path.
    signal(SIGTERM, SIG_IGN)
    sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource?.setEventHandler { NSApp.terminate(nil) }
    sigtermSource?.resume()

    // Seed a position near the right edge (by the clock). Without this, new
    // status items are inserted at the far LEFT of the status area, which on
    // a notched MacBook with a full menu bar can be hidden.
    let autosaveName = "UnSleepStatusItem"
    let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
    if UserDefaults.standard.object(forKey: positionKey) == nil {
      UserDefaults.standard.set(40, forKey: positionKey)
    }

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.autosaveName = autosaveName

    let menu = NSMenu()
    menu.delegate = self

    statusLine = NSMenuItem(title: "Off", action: nil, keyEquivalent: "")
    menu.addItem(statusLine)
    menu.addItem(.separator())

    toggleItem = NSMenuItem(title: "Keep Awake", action: #selector(toggleAction), keyEquivalent: "")
    toggleItem.target = self
    menu.addItem(toggleItem)

    let forItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
    let forMenu = NSMenu()
    for (title, minutes) in [
      ("15 Minutes", 15), ("30 Minutes", 30), ("1 Hour", 60),
      ("2 Hours", 120), ("4 Hours", 240), ("8 Hours", 480),
    ] {
      let item = NSMenuItem(title: title, action: #selector(forAction(_:)), keyEquivalent: "")
      item.target = self
      item.tag = minutes
      forMenu.addItem(item)
    }
    forItem.submenu = forMenu
    menu.addItem(forItem)

    let scheduleItem = NSMenuItem(title: "Schedule…", action: #selector(scheduleAction), keyEquivalent: "")
    scheduleItem.target = self
    menu.addItem(scheduleItem)

    cancelScheduleItem = NSMenuItem(
      title: "Cancel Schedule", action: #selector(cancelScheduleAction), keyEquivalent: "")
    cancelScheduleItem.target = self
    cancelScheduleItem.isHidden = true
    menu.addItem(cancelScheduleItem)

    menu.addItem(.separator())
    setupItem = NSMenuItem(
      title: "Set Up Password-Free Mode…", action: #selector(setupPasswordFreeAction),
      keyEquivalent: "")
    setupItem.target = self
    setupItem.isHidden = true
    menu.addItem(setupItem)

    let quit = NSMenuItem(title: "Quit UnSleep", action: #selector(quitApp), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    statusItem.menu = menu

    checkPasswordFreeMode()

    controller.onChange = { [weak self] s in
      DispatchQueue.main.async { self?.uiStatus = s; self?.render() }
    }
    controller.onError = { [weak self] msg in
      DispatchQueue.main.async { self?.showError(msg) }
    }
    controller.onCheckIn = { [weak self] since in
      DispatchQueue.main.async { self?.showCheckIn(since: since) }
    }

    server = SocketServer(controller: controller)
    server.start()
    render()
  }

  func applicationWillTerminate(_ note: Notification) {
    server.stop()
    controller.shutdown()
  }

  // MARK: Actions

  @objc private func toggleAction() {
    DispatchQueue.global().async { [self] in
      let (_, err) = controller.toggle()
      if let err { DispatchQueue.main.async { self.showError(err) } }
    }
  }

  @objc private func forAction(_ sender: NSMenuItem) {
    let until = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
    DispatchQueue.global().async { [self] in
      let (_, err) = controller.set(from: nil, until: until)
      if let err { DispatchQueue.main.async { self.showError(err) } }
    }
  }

  @objc private func scheduleAction() {
    let fromPicker = makeTimePicker(offsetMinutes: 0)
    let toPicker = makeTimePicker(offsetMinutes: 60)
    let stack = NSStackView(views: [
      makeLabel("From"), fromPicker, makeLabel("To"), toPicker,
    ])
    stack.orientation = .horizontal
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 320, height: 28)

    let alert = NSAlert()
    alert.messageText = "Schedule Keep Awake"
    alert.informativeText =
      "Stays awake between these times (rolls to tomorrow if the window already passed; overnight windows are fine)."
    alert.accessoryView = stack
    alert.addButton(withTitle: "Schedule")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let cal = Calendar.current
    let f = cal.dateComponents([.hour, .minute], from: fromPicker.dateValue)
    let t = cal.dateComponents([.hour, .minute], from: toPicker.dateValue)
    let (from, until) = windowDates(fromHM: (f.hour!, f.minute!), toHM: (t.hour!, t.minute!))
    DispatchQueue.global().async { [self] in
      let (_, err) = controller.set(from: from, until: until)
      if let err { DispatchQueue.main.async { self.showError(err) } }
    }
  }

  @objc private func cancelScheduleAction() {
    DispatchQueue.global().async { [self] in _ = controller.off() }
  }

  @objc private func quitApp() { NSApp.terminate(nil) }

  // MARK: Long-session check-in

  private func showCheckIn(since: Date) {
    let elapsed = Date().timeIntervalSince(since)
    let duration: String
    if elapsed >= 2 * 3600 {
      let h = Int(elapsed / 3600)
      duration = "\(h) hour\(h == 1 ? "" : "s")"
    } else {
      let m = max(1, Int(elapsed / 60))
      duration = "\(m) minute\(m == 1 ? "" : "s")"
    }
    let limit = uiStatus.until.map { " (set to end at \(timeFmt.string(from: $0)))" }
      ?? " with no time limit"

    let alert = NSAlert()
    alert.messageText = "Still keeping your Mac awake?"
    alert.informativeText =
      "UnSleep has been on for \(duration)\(limit). "
      + "Sleep — including lid-close sleep — is still disabled."
    alert.addButton(withTitle: "Keep Awake")
    alert.addButton(withTitle: "Turn Off")
    NSApp.activate(ignoringOtherApps: true)
    let keepGoing = alert.runModal() == .alertFirstButtonReturn

    DispatchQueue.global().async { [weak self] in
      guard let self else { return }
      if keepGoing {
        self.controller.extendCheckIn()
      } else {
        let (_, err) = self.controller.off()
        if let err { DispatchQueue.main.async { self.showError(err) } }
      }
    }
  }

  // MARK: Password-free mode setup

  /// On launch: hide the setup item if the rule is installed; otherwise offer
  /// setup once (the menu item stays available if the user declines).
  private func checkPasswordFreeMode() {
    DispatchQueue.global().async { [weak self] in
      let installed = PasswordFree.isInstalled()
      DispatchQueue.main.async {
        guard let self else { return }
        self.setupItem.isHidden = installed
        let promptedKey = "PasswordFreePromptedWithPolicyCheck"
        if !installed, !UserDefaults.standard.bool(forKey: promptedKey) {
          self.offerPasswordFreeSetup()
          UserDefaults.standard.set(true, forKey: promptedKey)
        }
      }
    }
  }

  @objc private func setupPasswordFreeAction() { offerPasswordFreeSetup() }

  private func offerPasswordFreeSetup() {
    let alert = NSAlert()
    alert.messageText = "Make UnSleep password-free?"
    alert.informativeText = """
      Turning UnSleep on or off changes power settings with pmset, which \
      normally asks for your admin password every time.

      UnSleep can install a rule (\(PasswordFree.rulePath)) that lets exactly \
      three pmset commands run without a password — nothing else gains \
      privileges. You'll be asked for your password once to install it.

      Remove it anytime:  sudo rm \(PasswordFree.rulePath)
      """
    alert.addButton(withTitle: "Install…")
    alert.addButton(withTitle: "Not Now")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    DispatchQueue.global().async { [weak self] in
      let ok = PasswordFree.install() && PasswordFree.isInstalled()
      DispatchQueue.main.async {
        guard let self else { return }
        self.setupItem.isHidden = ok
        let result = NSAlert()
        result.messageText = ok ? "Password-free mode enabled" : "Setup didn't complete"
        result.informativeText = ok
          ? "UnSleep will no longer ask for your password."
          : "The rule was not installed (cancelled or validation failed). "
            + "You can retry from the menu: Set Up Password-Free Mode…"
        result.alertStyle = ok ? .informational : .warning
        NSApp.activate(ignoringOtherApps: true)
        result.runModal()
      }
    }
  }

  // MARK: Rendering

  func menuWillOpen(_ menu: NSMenu) {
    uiStatus = controller.currentStatus()
    render()
  }

  private func render() {
    let s = uiStatus
    let pending = !s.active && s.from != nil
    if let button = statusItem.button {
      let (symbol, fallback): (String, String) =
        s.active ? ("moon.stars.fill", "🌙") : pending ? ("clock", "⏰") : ("sun.max.fill", "☀️")
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusText(s))
      button.image = image
      button.title = image == nil ? fallback : ""
      button.toolTip = "UnSleep — \(statusText(s))"
    }
    statusLine.title = statusText(s)
    toggleItem.state = s.active ? .on : .off
    cancelScheduleItem.isHidden = !pending
  }

  private func statusText(_ s: Controller.Snapshot) -> String {
    if s.active {
      guard let until = s.until else { return "On (no time limit)" }
      let mins = max(0, Int(until.timeIntervalSinceNow / 60))
      return "On until \(timeFmt.string(from: until)) (\(mins)m left)"
    }
    if let from = s.from {
      let end = s.until.map { " until \(timeFmt.string(from: $0))" } ?? ""
      return "Off — starts \(timeFmt.string(from: from))\(end)"
    }
    return "Off"
  }

  private func showError(_ msg: String) {
    let alert = NSAlert()
    alert.messageText = "UnSleep"
    alert.informativeText = msg
    alert.alertStyle = .warning
    alert.runModal()
  }

  // MARK: Helpers

  private func makeTimePicker(offsetMinutes: Int) -> NSDatePicker {
    let picker = NSDatePicker()
    picker.datePickerElements = .hourMinute
    picker.datePickerStyle = .textFieldAndStepper
    picker.dateValue = Date().addingTimeInterval(TimeInterval(offsetMinutes * 60))
    picker.setFrameSize(NSSize(width: 90, height: 24))
    return picker
  }

  private func makeLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
    return label
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
