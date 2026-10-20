import AppKit

// Take Control: CPU temperature and one fan slider in a small window, opened from the menu bar.

let helperPath = "/Library/PrivilegedHelperTools/com.takecontrol.helper"

enum Fans {
    static func count() -> Int {
        var n: Float = 0
        return smc_read_float("FNum", &n) && n > 0 && n < 10 ? Int(n) : 0
    }
    static func read(_ fan: Int, _ suffix: String) -> Float? {
        var v: Float = 0
        return smc_read_float("F\(fan)\(suffix)", &v) ? v : nil
    }
    static func isManual() -> Bool {
        (0..<count()).contains { read($0, "Md") == 1 }
    }
    /// "1234 RPM", "Stopped" or "--".
    static func speed(_ fan: Int) -> String {
        guard let rpm = read(fan, "Ac") else { return "--" }
        return rpm < 1 ? "Stopped" : "\(Int(rpm)) RPM"
    }
}

/// Overheat warning: hottest sensor at or above `hot` while a fan is stopped or in the bottom quarter
/// of its range, on two checks in a row. It clears once the CPU is back under `cool`.
enum Overheat {
    static let hot: Float = 100, cool: Float = 90
    static let interval: TimeInterval = 10

    static func fanIsLow() -> Bool {
        (0..<Fans.count()).contains { f in
            guard let rpm = Fans.read(f, "Ac") else { return false }
            if rpm < 1 { return true }
            guard let mn = Fans.read(f, "Mn"), let mx = Fans.read(f, "Mx"), mx > mn else { return false }
            return rpm < mn + (mx - mn) * 0.25
        }
    }
}

func cpuTemps() -> ArraySlice<Float> {
    var buf = [Float](repeating: 0, count: 64)
    return buf[0..<Int(hid_cpu_temps(&buf, 64))]
}

/// Owns the setuid helper process. Closing its stdin restores automatic fan control.
final class Helper {
    private var process: Process?
    private var input: FileHandle?
    /// Called on the main thread when the helper exits without being asked to.
    var onUnexpectedExit: (() -> Void)?

    var bundled: String? { Bundle.main.path(forAuxiliaryExecutable: "tc-helper") }
    var isRunning: Bool { process != nil }

    var isInstalled: Bool {
        guard let bundled,
              let attrs = try? FileManager.default.attributesOfItem(atPath: helperPath),
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue, perms & 0o4000 != 0
        else { return false }
        return FileManager.default.contentsEqual(atPath: bundled, andPath: helperPath)
    }

    /// Copies the helper into place with an admin prompt. One time, or after an update.
    /// Returns an error message, or nil on success.
    func install() -> String? {
        guard let bundled else { return "The helper is missing from the app bundle. Rebuild with ./build.sh." }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "mkdir -p /Library/PrivilegedHelperTools && cp -f \(q(bundled)) \(q(helperPath))"
            + " && chown root:wheel \(q(helperPath)) && chmod 4755 \(q(helperPath))"
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
            + " with prompt \"Take Control needs to install a small helper to set the fan speed.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled. The fan stays automatic." }
            return "Couldn't install the helper: \(error[NSAppleScript.errorMessage] as? String ?? "unknown error")"
        }
        return isInstalled ? nil : "The helper was copied but isn't setuid root."
    }

    /// Sends a level in per mille (0...1000), or nil for automatic control.
    /// Returns an error message, or nil on success.
    @discardableResult
    func send(_ level: Int?) -> String? {
        if process == nil {
            if level == nil && !Fans.isManual() { return nil }
            if !isInstalled, let err = install() { return err }
            if let err = start() { return err }
        }
        let line = level.map { "\($0)\n" } ?? "auto\n"
        do { try input?.write(contentsOf: Data(line.utf8)) } catch {
            stop()
            return "Lost contact with the helper."
        }
        if level == nil { stop() }
        return nil
    }

    private func start() -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: helperPath)
        p.standardInput = pipe
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.process = nil
                self.input = nil
                self.onUnexpectedExit?()
            }
        }
        do { try p.run() } catch { return "Couldn't start the helper: \(error.localizedDescription)" }
        process = p
        input = pipe.fileHandleForWriting
        return nil
    }

    /// Closing the pipe makes the helper restore automatic control and exit.
    func stop() {
        process = nil
        try? input?.close()
        input = nil
    }
}

final class MainController: NSViewController {
    private let temp = NSTextField(labelWithString: "-- °C")
    private let detail = NSTextField(labelWithString: "")
    private let fanSpeed = NSTextField(labelWithString: "--")
    private let mode = NSSegmentedControl(labels: ["Automatic", "Manual"], trackingMode: .selectOne, target: nil, action: nil)
    private let slider = NSSlider(value: 300, minValue: 0, maxValue: 1000, target: nil, action: nil)
    private let target = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    let helper = Helper()

    private var isManual: Bool { mode.selectedSegment == 1 }
    private var level: Int { Int(slider.doubleValue.rounded()) }

    override func loadView() {
        temp.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        fanSpeed.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        fanSpeed.textColor = .secondaryLabelColor
        target.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        target.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.textColor = .systemOrange

        mode.selectedSegment = 0
        mode.segmentDistribution = .fillEqually
        mode.target = self
        mode.action = #selector(modeChanged)
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true

        let cpuTitle = NSTextField(labelWithString: "CPU Temperature")
        let fanTitle = NSTextField(labelWithString: "Fan")
        for t in [cpuTitle, fanTitle] { t.font = .systemFont(ofSize: 13, weight: .semibold) }
        let fanRow = NSStackView(views: [fanTitle, NSView(), fanSpeed])
        let sliderLabels = NSStackView(views: [small("Quiet"), NSView(), target, NSView(), small("Max")])
        let line = NSBox()
        line.boxType = .separator

        let stack = NSStackView(views: [cpuTitle, temp, detail, line, fanRow, mode, slider, sliderLabels, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(2, after: cpuTitle)
        stack.setCustomSpacing(16, after: detail)
        stack.setCustomSpacing(16, after: line)
        stack.setCustomSpacing(12, after: mode)
        stack.setCustomSpacing(2, after: slider)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        for v in [line, fanRow, mode, slider, sliderLabels, status] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 340).isActive = true
        #if TEST_WARNING
        // Test build only (TEST=1 ./build.sh): fires the overheat warning on demand.
        stack.addArrangedSubview(NSButton(title: "Test Overheat Warning", target: self, action: #selector(testWarning)))
        #endif
        view = stack

        helper.onUnexpectedExit = { [weak self] in
            self?.setMode(manual: false, error: "The helper stopped. The fan is back on automatic.")
        }
        if Fans.count() == 0 {
            mode.isEnabled = false
            status.stringValue = "No fans found on this Mac."
        }
        syncControls()
    }

    private func small(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 11)
        f.textColor = .tertiaryLabelColor
        return f
    }

    #if TEST_WARNING
    var onTestWarning: (() -> Void)?
    @objc private func testWarning() { onTestWarning?() }
    #endif

    /// Hands the fan back to macOS, as if "Automatic" had been picked.
    func setAutomatic() {
        mode.selectedSegment = 0
        modeChanged()
    }

    @objc private func modeChanged() {
        status.stringValue = isManual ? "Taking control of the fan…" : ""
        status.displayIfNeeded()
        let err = helper.send(isManual ? level : nil)
        setMode(manual: isManual && err == nil, error: err)
        refresh()
    }

    @objc private func sliderMoved() {
        updateTarget()
        if isManual, let err = helper.send(level) { setMode(manual: false, error: err) }
    }

    private func setMode(manual: Bool, error: String?) {
        mode.selectedSegment = manual ? 1 : 0
        status.stringValue = error ?? ""
        syncControls()
    }

    private func syncControls() {
        slider.isEnabled = isManual
        target.alphaValue = isManual ? 1 : 0.5
        updateTarget()
    }

    private func updateTarget() {
        guard let mn = Fans.read(0, "Mn"), let mx = Fans.read(0, "Mx"), mx > mn else { target.stringValue = ""; return }
        target.stringValue = "\(Int(mn + (mx - mn) * Float(level) / 1000)) RPM"
    }

    func refresh() {
        let t = cpuTemps()
        let n = t.count
        if n > 0 {
            temp.stringValue = String(format: "%.0f °C", t.max()!)
            detail.stringValue = String(format: "Hottest of %d sensors · average %.0f °C", n, t.reduce(0, +) / Float(n))
        } else {
            temp.stringValue = "-- °C"
            detail.stringValue = "No CPU sensors found"
        }

        fanSpeed.stringValue = Fans.count() > 0 ? Fans.speed(0) : "--"
        if isManual && helper.isRunning {
            // The helper keeps retrying, so this clears once macOS hands the fan over.
            status.stringValue = Fans.isManual() ? "" : "Waiting for macOS to release the fan…"
        }
    }

    func setUpdating(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.5
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = MainController()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    /// Read-only lines at the top of the menu bar menu; controls live in the window.
    private var readouts: [NSMenuItem] = []
    private var menuTimer: Timer?
    private var watchdog: Timer?
    private var hotChecks = 0
    private var warning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        smc_open()
        // Fans left in manual mode by an earlier session: hand them back to the system.
        if Fans.isManual() && controller.helper.isInstalled { controller.helper.send(nil) }

        NSApp.mainMenu = makeMenu()
        window = NSWindow(contentViewController: controller)
        window.title = "Take Control"
        window.styleMask = [.titled, .closable]
        // See-through window: 20% opaque background over a radius 30 blur of what's behind it.
        window.isOpaque = false
        window.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.2)
        window.titlebarAppearsTransparent = true
        // Closing only hides the window; the app keeps running and holding the fan.
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Main")
        // Only poll the sensors while the window is actually on screen.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.controller.setUpdating(self.window.occlusionState.contains(.visible))
        }
        statusItem = makeStatusItem()
        showWindow()
        controller.setUpdating(true)
        startWatchdog()
        #if TEST_WARNING
        controller.onTestWarning = { [weak self] in self?.setWarning(true, temp: cpuTemps().max() ?? 0) }
        #endif
    }

    /// The one always-on timer: a cheap temperature and fan check every 10s, even with no UI open,
    /// so a stopped or slow fan on a hot CPU is never missed. Skipped on Macs without fans.
    private func startWatchdog() {
        guard Fans.count() > 0 else { return }
        let timer = Timer(timeInterval: Overheat.interval, repeats: true) { [weak self] _ in self?.checkOverheat() }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkOverheat() {
        let hottest = cpuTemps().max() ?? 0
        if warning {
            if hottest < Overheat.cool { setWarning(false) }
            return
        }
        hotChecks = hottest >= Overheat.hot && Overheat.fanIsLow() ? hotChecks + 1 : 0
        if hotChecks >= 2 { setWarning(true, temp: hottest) }
    }

    /// Turns the menu bar icon into a red warning triangle and puts a critical alert in front of everything.
    private func setWarning(_ on: Bool, temp: Float = 0) {
        warning = on
        hotChecks = 0
        let button = statusItem.button
        if on {
            button?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Overheating")
            button?.contentTintColor = .systemRed
            button?.toolTip = "Take Control: CPU is overheating and the fan is slow"
        } else {
            button?.image = NSImage(named: "MenuBarIcon")
            button?.contentTintColor = nil
            button?.toolTip = "Take Control"
            return
        }

        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(format: "CPU is at %.0f °C and the fan is barely spinning", temp)
        let manual = controller.helper.isRunning
        alert.informativeText = manual
            ? "Your manual fan setting is too low for this load. Return the fan to automatic, or raise the slider."
            : "The fan is on automatic but isn't keeping up. Save your work and reduce the load. If this keeps happening, the fan may be faulty."
        if manual { alert.addButton(withTitle: "Return Fan to Automatic") }
        alert.addButton(withTitle: manual ? "Ignore" : "OK")
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn && manual { controller.setAutomatic() }
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Needs a window number, so set it once the window is on screen.
        _ = CGSSetWindowBackgroundBlurRadius(CGSMainConnectionID(), Int32(window.windowNumber), 30)
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true
            item.button?.image = icon
        } else {
            item.button?.title = "TC"
        }
        item.button?.toolTip = "Take Control"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for _ in 0..<1 + max(Fans.count(), 1) {
            // Enabled with no action, so the text isn't greyed out.
            readouts.append(menu.addItem(withTitle: "", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Take Control…", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Take Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        return item
    }

    private func updateReadouts() {
        let t = cpuTemps()
        var lines = [("CPU", t.isEmpty ? "-- °C" : String(format: "%.0f °C", t.max()!))]
        let fans = Fans.count()
        let mode = controller.helper.isRunning ? " · Manual" : " · Auto"
        if fans == 0 { lines.append(("Fan", "None")) }
        for f in 0..<fans {
            lines.append((fans > 1 ? "Fan \(f + 1)" : "Fan", Fans.speed(f) + mode))
        }
        let tab = NSTextTab(textAlignment: .right, location: 170)
        let style = NSMutableParagraphStyle()
        style.tabStops = [tab]
        for (item, (name, value)) in zip(readouts, lines) {
            item.attributedTitle = NSAttributedString(string: "\(name)\t\(value)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .paragraphStyle: style,
            ])
        }
    }

    // Sensors are only read while the menu is open.
    func menuWillOpen(_ menu: NSMenu) {
        updateReadouts()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.updateReadouts() }
        timer.tolerance = 0.5
        // .common so it also fires while the menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        menuTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTimer?.invalidate()
        menuTimer = nil
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Take Control", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Take Control", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Take Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = app

        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = win
        NSApp.windowsMenu = win
        return main
    }

    // Closing the window keeps the app (and fan control) running. Quit from the menu bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Opening the app again (Finder, Spotlight) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.helper.send(nil)
        smc_close()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon: the app lives in the menu bar.
app.setActivationPolicy(.accessory)
app.run()
