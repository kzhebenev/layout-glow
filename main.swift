import Cocoa
import Carbon
import ServiceManagement
import IOKit.hid

// MARK: - Внешний вид

struct Style {
    let color: NSColor
    let alpha: CGFloat   // постоянная яркость свечения
    let label: String
}

let styles: [String: Style] = [
    "Russian": Style(color: NSColor(red: 1.00, green: 0.45, blue: 0.10, alpha: 1), alpha: 0.55, label: "RU"),
    "ABC":     Style(color: NSColor(red: 0.15, green: 0.55, blue: 1.00, alpha: 1), alpha: 0.28, label: "EN"),
]
let fallbackStyle = Style(color: .systemPurple, alpha: 0.45, label: "??")
let capsStyle = Style(color: NSColor(red: 0.95, green: 0.15, blue: 0.35, alpha: 1), alpha: 0.60, label: "CAPS")

let glowHeight: CGFloat = 48     // высота полосы свечения у нижнего края
let flashAlpha: CGFloat = 0.95   // вспышка в момент переключения
let pillLifetime = 1.0           // сколько секунд висит плашка
let caretBadgeHeight: CGFloat = 22   // ярлык раскладки у курсора
let caretDotLifetime = 1.6

// MARK: - Поведение

let maxFnTap = 0.6               // дольше держал Fn — не тап
let doubleShiftWindow = 0.5      // окно двойного тапа Shift
let expandKeycode: UInt32 = 29   // Cmd+Option+0 — развернуть ключ вставки
let slotKeycodes: Set<Int64> = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]  // цифры 0...9
let maxWordLen = 32
let syntheticMagic: Int64 = 0x4C474C4F  // метка наших синтетических событий
let releasesAPI = "https://api.github.com/repos/kzhebenev/layout-glow/releases/latest"
let releasesPage = "https://github.com/kzhebenev/layout-glow/releases/latest"

// Приложения, где автоисправление выключено по умолчанию (меняется в меню)
let defaultExcludedApps = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
    "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "com.github.wez.wezterm",
]

// MARK: - Настройки

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "fnSwitch": true,
            "autoCorrect": true,
            "manualConvert": true,
            "perAppLayout": false,
            "capsGlow": true,
            "caretDot": true,
            "excludedApps": defaultExcludedApps,
            "appLayouts": [String: String](),
        ])
    }

    var fnSwitch: Bool {
        get { d.bool(forKey: "fnSwitch") }
        set { d.set(newValue, forKey: "fnSwitch") }
    }
    var autoCorrect: Bool {
        get { d.bool(forKey: "autoCorrect") }
        set { d.set(newValue, forKey: "autoCorrect") }
    }
    var manualConvert: Bool {
        get { d.bool(forKey: "manualConvert") }
        set { d.set(newValue, forKey: "manualConvert") }
    }
    var perAppLayout: Bool {
        get { d.bool(forKey: "perAppLayout") }
        set { d.set(newValue, forKey: "perAppLayout") }
    }
    var capsGlow: Bool {
        get { d.bool(forKey: "capsGlow") }
        set { d.set(newValue, forKey: "capsGlow") }
    }
    var caretDot: Bool {
        get { d.bool(forKey: "caretDot") }
        set { d.set(newValue, forKey: "caretDot") }
    }
    var excludedApps: Set<String> {
        get { Set(d.stringArray(forKey: "excludedApps") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "excludedApps") }
    }
    var appLayouts: [String: String] {
        get { d.dictionary(forKey: "appLayouts") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "appLayouts") }
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let b = bundleID else { return false }
        return excludedApps.contains(b)
    }
    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        var s = excludedApps
        if excluded { s.insert(bundleID) } else { s.remove(bundleID) }
        excludedApps = s
    }
}

// MARK: - Свечение

final class GlowView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let gradient = NSGradient(colors: [color, color.withAlphaComponent(0)])
        gradient?.draw(in: bounds, angle: 90)
    }
}

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var glowWindows: [NSWindow] = []
    var pillWindow: NSWindow?
    var pillTimer: Timer?
    var caretWindow: NSWindow?
    var caretTimer: Timer?
    var lastLayout = ""
    var statusItem: NSStatusItem?

    var eventTap: CFMachPort?
    var fnDown = false
    var fnUsedAsModifier = false
    var fnDownAt: TimeInterval = 0
    var accessRequested = false
    var capsOn = false

    var wordBuffer: [Stroke] = []
    var lastWord: [Stroke]?
    var lastWordTrailing = 0
    var shiftDown = false
    var shiftUsedAsModifier = false
    var lastShiftTapAt: TimeInterval = 0
    var replaceInProgress = false
    var lastAutoTyped: String?
    var frontApp: NSRunningApplication?
    var restoringLayout = false

    var hotKeyRefs: [EventHotKeyRef?] = []
    var manualAXEnabled = Set<pid_t>()

    let exceptionsFile = WordFile(name: "exceptions.txt", header: exceptionsHeader)
    let commandsFile = WordFile(name: "commands.txt", header: commandsHeader, defaults: defaultCommands)
    let snippetsFile = SnippetFile(name: "snippets.txt", header: "", defaults: defaultSnippets)

    // Диагностика
    var keysSeen = 0
    var shiftTaps = 0
    var events: [String] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        if Bundle.main.bundlePath.hasSuffix(".app"),
           SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        buildGlowWindows()
        buildStatusItem()
        capsOn = NSEvent.modifierFlags.contains(.capsLock)
        apply(layout: currentLayout(), animated: false)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(layoutChanged),
            name: NSNotification.Name("AppleSelectedInputSourcesChangedNotification"),
            object: nil, suspensionBehavior: .deliverImmediately)

        // Отладочный триггер: показать тестовую точку без открытия меню
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(testDot),
            name: NSNotification.Name("ru.devkz.layoutglow.testdot"),
            object: nil, suspensionBehavior: .deliverImmediately)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        frontApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self,
                  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.frontApp = app
                self.enableManualAccessibility(for: app)
                self.restoreLayout(for: app)
            }
            self.wordBuffer.removeAll()
            self.lastWord = nil
        }

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = currentLayout()
            if now != self.lastLayout { self.apply(layout: now, animated: true) }
            self.exceptionsFile.reload()
            self.commandsFile.reload()
            self.snippetsFile.reload()
        }

        startTap()
        registerSlotHotkeys()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.4)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.writeStatus() }
        writeStatus()

        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.checkForUpdates(manual: false) }
    }

    // MARK: Окна свечения

    func buildGlowWindows() {
        glowWindows.forEach { $0.orderOut(nil) }
        glowWindows = NSScreen.screens.map { screen in
            let f = screen.frame
            let w = NSWindow(
                contentRect: NSRect(x: f.minX, y: f.minY, width: f.width, height: glowHeight),
                styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.contentView = GlowView()
            w.orderFrontRegardless()
            return w
        }
    }

    @objc func screensChanged() {
        buildGlowWindows()
        apply(layout: lastLayout, animated: false)
    }

    @objc func layoutChanged() {
        let now = currentLayout()
        if now != lastLayout { apply(layout: now, animated: true) }
        rememberLayout()
    }

    func currentStyle() -> Style {
        if capsOn && Settings.shared.capsGlow { return capsStyle }
        return styles[lastLayout] ?? fallbackStyle
    }

    func apply(layout: String, animated: Bool) {
        lastLayout = layout
        refreshGlow(animated: animated)
        if animated {
            let style = currentStyle()
            showPill(text: style.label, color: style.color)
            showCaretDot(color: style.color)
        }
    }

    func refreshGlow(animated: Bool) {
        let style = currentStyle()
        statusItem?.button?.title = style.label
        for w in glowWindows {
            (w.contentView as? GlowView)?.color = style.color
            if animated {
                w.alphaValue = flashAlpha
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.6
                    w.animator().alphaValue = style.alpha
                }
            } else {
                w.alphaValue = style.alpha
            }
        }
    }

    func showPill(text: String, color: NSColor) {
        pillTimer?.invalidate()
        pillWindow?.orderOut(nil)

        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: max(92, CGFloat(text.count) * 18 + 40), height: 44)
        let f = screen.frame
        let rect = NSRect(x: f.midX - size.width / 2, y: f.minY + 96,
                          width: size.width, height: size.height)

        let w = borderlessWindow(rect: rect)
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = color.withAlphaComponent(0.9).cgColor
        view.layer?.cornerRadius = 12

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (size.height - 28) / 2, width: size.width, height: 28)
        view.addSubview(label)

        w.contentView = view
        w.alphaValue = 1
        w.orderFrontRegardless()
        pillWindow = w

        pillTimer = Timer.scheduledTimer(withTimeInterval: pillLifetime, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                w.animator().alphaValue = 0
            }, completionHandler: {
                w.orderOut(nil)
                if self?.pillWindow === w { self?.pillWindow = nil }
            })
        }
    }

    func borderlessWindow(rect: NSRect) -> NSWindow {
        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return w
    }

    // MARK: Точка у курсора

    func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let f = focusedRef, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        return (f as! AXUIElement)
    }

    // Точные координаты каретки; отдают в основном нативные приложения
    func caretRect(_ element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        AXValueGetValue(rv as! AXValue, .cfRange, &range)
        range.length = 0

        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue, &boundsRef) == .success,
              let bv = boundsRef, CFGetTypeID(bv) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(bv as! AXValue, .cgRect, &rect)
        guard rect.width.isFinite, rect.height.isFinite, rect.height > 0 else { return nil }
        return rect
    }

    // Запасной путь: рамка самого поля ввода. Каретку не даёт, но точка
    // окажется у поля, а не в никуда — этого хватает, чтобы заметить цвет
    func fieldRect(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pv = posRef, let sv = sizeRef,
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        // Ставим точку у левого края поля, по центру первой строки
        return CGRect(x: origin.x, y: origin.y, width: 1, height: min(size.height, 22))
    }

    func showCaretDot(color: NSColor) {
        guard Settings.shared.caretDot, let primary = NSScreen.screens.first else { return }
        guard let element = focusedElement() else {
            // Electron мог не отдать дерево — просим его включить и пробуем ещё раз
            if let app = frontApp, !manualAXEnabled.contains(app.processIdentifier) {
                enableManualAccessibility(for: app)
                log("точка: включаю доступность в «\(app.localizedName ?? "?")», повтор")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.showCaretDot(color: color) }
            } else {
                log("точка: нет фокуса ввода (\(frontApp?.localizedName ?? "?"))")
            }
            return
        }
        let exact = caretRect(element)
        guard let rect = exact ?? fieldRect(element) else {
            log("точка: «\(frontApp?.localizedName ?? "?")» не отдаёт координаты")
            return
        }
        // Универсальный доступ отдаёт координаты от левого верхнего угла
        let flippedY = primary.frame.maxY - rect.maxY
        let origin = NSPoint(x: rect.maxX + 6, y: flippedY + rect.height / 2 - caretBadgeHeight / 2)
        log("точка: \(exact == nil ? "по рамке поля" : "у каретки") "
            + "AX(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))) "
            + "-> экран(\(Int(origin.x)),\(Int(origin.y))), экран высотой \(Int(primary.frame.maxY))")
        showDot(at: origin, color: color)
    }

    func showDot(at origin: NSPoint, color: NSColor) {
        caretTimer?.invalidate()
        caretWindow?.orderOut(nil)

        let text = currentStyle().label
        let size = NSSize(width: max(34, CGFloat(text.count) * 11 + 16), height: caretBadgeHeight)
        let w = borderlessWindow(rect: NSRect(origin: origin, size: size))

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = caretBadgeHeight / 2
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        view.layer?.borderWidth = 1.5
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowRadius = 4
        view.layer?.shadowOpacity = 0.35
        view.layer?.shadowOffset = CGSize(width: 0, height: -1)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (size.height - 15) / 2, width: size.width, height: 15)
        view.addSubview(label)

        w.contentView = view
        w.alphaValue = 1
        w.orderFrontRegardless()
        caretWindow = w

        caretTimer = Timer.scheduledTimer(withTimeInterval: caretDotLifetime, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                w.animator().alphaValue = 0
            }, completionHandler: {
                w.orderOut(nil)
                if self?.caretWindow === w { self?.caretWindow = nil }
            })
        }
    }

    // Electron (Claude, Termius, VS Code) держит дерево доступности выключенным,
    // пока его об этом не попросят
    func enableManualAccessibility(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, !manualAXEnabled.contains(pid) else { return }
        manualAXEnabled.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: Раскладка для каждого приложения

    func rememberLayout() {
        guard Settings.shared.perAppLayout, !restoringLayout,
              let bid = frontApp?.bundleIdentifier else { return }
        var map = Settings.shared.appLayouts
        map[bid] = currentLayoutFullID()
        Settings.shared.appLayouts = map
    }

    func restoreLayout(for app: NSRunningApplication) {
        guard Settings.shared.perAppLayout, let bid = app.bundleIdentifier,
              let wanted = Settings.shared.appLayouts[bid], wanted != currentLayoutFullID(),
              let source = layout(withID: wanted) else { return }
        restoringLayout = true
        TISSelectInputSource(source)
        log("раскладка для «\(appName(for: bid))»: \(wanted.components(separatedBy: ".").last ?? wanted)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.restoringLayout = false }
    }

    // MARK: Диагностика

    func log(_ line: String) {
        events.append(line)
        if events.count > 40 { events.removeFirst(events.count - 40) }
        writeStatus()
    }

    func writeStatus() {
        let fnUsage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString,
                                                "com.apple.HIToolbox" as CFString) as? Int ?? -1
        var text = """
        перехват клавиатуры: \(eventTap != nil ? "работает" : "НЕТ (нужен Мониторинг ввода)")
        универсальный доступ: \(AXIsProcessTrusted() ? "выдан" : "НЕ ВЫДАН")
        нажатий получено: \(keysSeen)
        тапов Shift: \(shiftTaps)
        в буфере слова: \(wordBuffer.count) симв.
        AppleFnUsageType: \(fnUsage) (0 = Do Nothing, тап Fn наш)
        раскладка: \(lastLayout), Caps Lock: \(capsOn ? "включён" : "выключен")
        активное приложение: \(frontApp?.bundleIdentifier ?? "—")
        словари: исключений \(exceptionsFile.words.count), команд \(commandsFile.words.count), вставок \(snippetsFile.items.count)
        раскладка по приложениям: \(Settings.shared.perAppLayout ? "вкл" : "выкл")

        события:
        """
        text += "\n" + events.joined(separator: "\n") + "\n"
        try? text.write(to: supportDirectory().appendingPathComponent("status.log"),
                        atomically: true, encoding: .utf8)
    }

    // MARK: Меню-бар

    static let knownAppNames: [String: String] = [
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm2",
        "dev.warp.Warp-Stable": "Warp",
        "net.kovidgoyal.kitty": "kitty",
        "com.mitchellh.ghostty": "Ghostty",
        "com.github.wez.wezterm": "WezTerm",
        "com.termius.mac": "Termius",
    ]

    func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        if let known = AppDelegate.knownAppNames[bundleID] { return known }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "??"
        item.button?.font = .systemFont(ofSize: 12, weight: .semibold)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        let layoutName = currentSource().map { sourceName($0) } ?? "—"
        menu.addItem(withTitle: "Раскладка: \(layoutName)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        func toggle(_ title: String, _ on: Bool, _ selector: Selector, in target: NSMenu? = nil) {
            let i = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            i.state = on ? .on : .off
            i.target = self
            (target ?? menu).addItem(i)
        }
        toggle("Быстрое переключение по Fn", s.fnSwitch, #selector(toggleFn))
        toggle("Автоисправление раскладки", s.autoCorrect, #selector(toggleAuto))
        toggle("Конвертация по двойному Shift", s.manualConvert, #selector(toggleManual))
        toggle("Своя раскладка для каждого приложения", s.perAppLayout, #selector(togglePerApp))
        toggle("Подсветка Caps Lock", s.capsGlow, #selector(toggleCaps))
        toggle("Точка у курсора", s.caretDot, #selector(toggleCaret))

        menu.addItem(.separator())
        if let app = frontApp, let bid = app.bundleIdentifier {
            let name = app.localizedName ?? appName(for: bid)
            toggle("Автоисправление в «\(name)»", !s.isExcluded(bid), #selector(toggleFrontApp))
        }
        let excluded = s.excludedApps.filter { isInstalled($0) }.sorted { appName(for: $0) < appName(for: $1) }
        if !excluded.isEmpty {
            let head = NSMenuItem(title: "Выключено в приложениях (\(excluded.count))", action: nil, keyEquivalent: "")
            menu.addItem(head)
            let sub = NSMenu()
            for bid in excluded {
                let i = NSMenuItem(title: appName(for: bid), action: #selector(removeExcludedApp(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = bid
                i.toolTip = "\(bid) — нажмите, чтобы включить автоисправление здесь"
                sub.addItem(i)
            }
            menu.setSubmenu(sub, for: head)
        }

        menu.addItem(.separator())
        let dictHead = NSMenuItem(title: "Словари", action: nil, keyEquivalent: "")
        menu.addItem(dictHead)
        let dicts = NSMenu()
        func fileItem(_ title: String, _ selector: Selector) {
            let i = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            i.target = self
            dicts.addItem(i)
        }
        fileItem("Исключения (\(exceptionsFile.words.count))…", #selector(openExceptions))
        fileItem("Системные команды (\(commandsFile.words.count))…", #selector(openCommands))
        fileItem("Вставки (\(snippetsFile.items.count))…", #selector(openSnippets))
        dicts.addItem(.separator())
        let reload = NSMenuItem(title: "Перечитать словари", action: #selector(reloadDictionaries), keyEquivalent: "")
        reload.target = self
        dicts.addItem(reload)
        let dotTest = NSMenuItem(title: "Проверить ярлык у курсора", action: #selector(testDot), keyEquivalent: "")
        dotTest.target = self
        dicts.addItem(dotTest)
        menu.setSubmenu(dicts, for: dictHead)

        // Слоты вставок Cmd+Option+цифра
        let slots = (1...9).compactMap { n -> (Int, String)? in
            guard let v = snippetsFile.value(for: String(n)) else { return nil }
            return (n, v)
        }
        if !slots.isEmpty {
            let head = NSMenuItem(title: "Быстрые вставки (\(slots.count))", action: nil, keyEquivalent: "")
            menu.addItem(head)
            let sub = NSMenu()
            for (n, value) in slots {
                let short = value.count > 40 ? String(value.prefix(40)) + "…" : value
                let i = NSMenuItem(title: "\(n): \(short)", action: #selector(insertSlotItem(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = n
                i.toolTip = "Cmd+Option+\(n)"
                sub.addItem(i)
            }
            menu.setSubmenu(sub, for: head)
        }

        menu.addItem(.separator())
        let i1 = NSMenuItem(title: "Мониторинг ввода: \(eventTap != nil ? "выдан" : "НЕ ВЫДАН")",
                            action: #selector(openInputMonitoring), keyEquivalent: "")
        i1.target = self
        menu.addItem(i1)
        let i2 = NSMenuItem(title: "Универсальный доступ: \(AXIsProcessTrusted() ? "выдан" : "НЕ ВЫДАН")",
                            action: #selector(openAccessibility), keyEquivalent: "")
        i2.target = self
        menu.addItem(i2)

        menu.addItem(.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let upd = NSMenuItem(title: "LayoutGlow \(version) — проверить обновления",
                             action: #selector(checkUpdatesManually), keyEquivalent: "")
        upd.target = self
        menu.addItem(upd)
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleFn() { Settings.shared.fnSwitch.toggle() }
    @objc func toggleAuto() { Settings.shared.autoCorrect.toggle() }
    @objc func toggleManual() { Settings.shared.manualConvert.toggle() }
    @objc func togglePerApp() {
        Settings.shared.perAppLayout.toggle()
        if Settings.shared.perAppLayout { rememberLayout() }
    }
    @objc func toggleCaps() { Settings.shared.capsGlow.toggle(); refreshGlow(animated: false) }
    @objc func toggleCaret() { Settings.shared.caretDot.toggle() }
    @objc func toggleFrontApp() {
        guard let bid = frontApp?.bundleIdentifier else { return }
        Settings.shared.setExcluded(bid, !Settings.shared.isExcluded(bid))
    }
    @objc func removeExcludedApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        Settings.shared.setExcluded(bid, false)
    }
    @objc func openExceptions() { NSWorkspace.shared.open(exceptionsFile.url) }
    @objc func openCommands() { NSWorkspace.shared.open(commandsFile.url) }
    @objc func openSnippets() { NSWorkspace.shared.open(snippetsFile.url) }
    @objc func reloadDictionaries() {
        exceptionsFile.reload(force: true)
        commandsFile.reload(force: true)
        snippetsFile.reload(force: true)
        showPill(text: "словари", color: .systemGray)
    }
    @objc func testDot() {
        guard let screen = NSScreen.main else { return }
        let origin = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        log("тест точки в центре экрана: (\(Int(origin.x)),\(Int(origin.y)))")
        showDot(at: origin, color: currentStyle().color)
    }

    @objc func insertSlotItem(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? Int else { return }
        insertSlot(n)
    }
    @objc func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func checkUpdatesManually() { checkForUpdates(manual: true) }

    // MARK: Перехват клавиатуры

    func startTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            me.handleTapEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            if !accessRequested {
                accessRequested = true
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startTap() }
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handleTapEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMagic { return }

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            wordBuffer.removeAll(); lastWord = nil
            return
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let caps = event.flags.contains(.maskAlphaShift)
        if caps != capsOn {
            capsOn = caps
            DispatchQueue.main.async {
                self.refreshGlow(animated: true)
                if Settings.shared.capsGlow {
                    let st = self.currentStyle()
                    self.showPill(text: st.label, color: st.color)
                }
            }
        }

        switch type {
        case .flagsChanged where keycode == 63:  // Fn/Globe
            if shiftDown { shiftUsedAsModifier = true }
            let pressed = event.flags.contains(.maskSecondaryFn)
            if pressed && !fnDown {
                fnDown = true
                fnUsedAsModifier = false
                fnDownAt = ProcessInfo.processInfo.systemUptime
            } else if !pressed && fnDown {
                fnDown = false
                let held = ProcessInfo.processInfo.systemUptime - fnDownAt
                if Settings.shared.fnSwitch && !fnUsedAsModifier && held < maxFnTap {
                    DispatchQueue.main.async { self.toggleLayout() }
                }
            }
        case .flagsChanged where keycode == 56 || keycode == 60:  // Shift
            if fnDown { fnUsedAsModifier = true }
            let pressed = event.flags.contains(.maskShift)
            if pressed && !shiftDown {
                shiftDown = true
                shiftUsedAsModifier = false
            } else if !pressed && shiftDown {
                shiftDown = false
                if !shiftUsedAsModifier { handleShiftTap() } else { lastShiftTapAt = 0 }
            }
        case .flagsChanged:
            if fnDown { fnUsedAsModifier = true }
            if shiftDown { shiftUsedAsModifier = true }
        case .keyDown:
            if fnDown { fnUsedAsModifier = true }
            if shiftDown { shiftUsedAsModifier = true }
            lastShiftTapAt = 0
            trackKey(event: event, keycode: keycode)
        default:
            break
        }
    }

    // Двойной тап Shift — конвертация, сразу, без ожидания третьего тапа
    func handleShiftTap() {
        guard Settings.shared.manualConvert else { return }
        let now = ProcessInfo.processInfo.systemUptime
        shiftTaps += 1
        if now - lastShiftTapAt < doubleShiftWindow {
            lastShiftTapAt = 0
            DispatchQueue.main.async { self.manualConvert() }
        } else {
            lastShiftTapAt = now
        }
    }

    func toggleLayout() {
        if let v = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString,
                                             "com.apple.HIToolbox" as CFString) as? Int, v != 0 {
            return
        }
        let list = enabledLayouts()
        guard list.count > 1 else { return }
        let current = currentLayoutFullID()
        let index = list.firstIndex(where: { sourceID($0) == current }) ?? 0
        TISSelectInputSource(list[(index + 1) % list.count])
    }

    // MARK: Буфер слова и автоисправление

    func trackKey(event: CGEvent, keycode: Int64) {
        guard Settings.shared.autoCorrect || Settings.shared.manualConvert else { return }
        if IsSecureEventInputEnabled() { wordBuffer.removeAll(); lastWord = nil; return }
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            // Своё сочетание Cmd+Option+цифра буфер не сбрасывает:
            // иначе набранный ключ вставки стирается перед разворотом
            if flags.contains(.maskCommand), flags.contains(.maskAlternate),
               slotKeycodes.contains(keycode) { return }
            wordBuffer.removeAll(); lastWord = nil
            return
        }
        switch keycode {
        case 49:  // пробел — граница слова
            let word = wordBuffer
            wordBuffer.removeAll()
            if !word.isEmpty {
                lastWord = word
                lastWordTrailing = 1
                if Settings.shared.autoCorrect { DispatchQueue.main.async { self.autoCorrect(word) } }
            } else if lastWord != nil {
                lastWordTrailing = min(lastWordTrailing + 1, 4)
            }
        case 51:  // backspace
            if wordBuffer.isEmpty { lastWord = nil } else { wordBuffer.removeLast() }
        case 36, 76, 48, 53, 117, 115, 116, 119, 121, 123, 124, 125, 126:
            wordBuffer.removeAll(); lastWord = nil
        default:
            let stroke = Stroke(keycode: CGKeyCode(keycode), shift: flags.contains(.maskShift),
                                caps: flags.contains(.maskAlphaShift))
            if let cur = currentSource(), !translate([stroke], via: cur).isEmpty {
                keysSeen += 1
                wordBuffer.append(stroke)
                if wordBuffer.count > maxWordLen { wordBuffer.removeAll(); lastWord = nil }
            }
        }
    }

    func autoCorrect(_ word: [Stroke]) {
        guard !word.isEmpty, let cur = currentSource(), let other = otherLayout() else { return }
        if Settings.shared.isExcluded(frontApp?.bundleIdentifier) { return }

        let typed = translate(word, via: cur)
        let converted = translate(word, via: other)
        let decision = correctionDecision(
            typed: typed, converted: converted,
            srcLang: sourceLang(cur), dstLang: sourceLang(other),
            commands: commandsFile.words, exceptions: exceptionsFile.words,
            capsOn: word.contains(where: { $0.caps }))

        guard decision.correct else {
            log("пропуск «\(typed)»: \(decision.reason)")
            return
        }
        log("исправлено «\(typed)» -> «\(converted)»")
        lastAutoTyped = typed
        performReplace(strokes: word, trailingSpaces: 1, to: other)
        lastWord = word
        lastWordTrailing = 1
    }

    // MARK: Ручная конвертация и вставки

    func manualConvert() {
        if convertSelection() { log("двойной Shift: конвертирован выделенный текст"); return }

        guard let other = otherLayout() else { log("двойной Shift: нет второй раскладки"); return }
        let strokes: [Stroke]
        let trailing: Int
        if !wordBuffer.isEmpty {
            strokes = wordBuffer; trailing = 0
        } else if let lw = lastWord {
            strokes = lw; trailing = lastWordTrailing
        } else {
            log("двойной Shift: нечего конвертировать (буфер пуст)")
            return
        }

        // Откат автоисправления = слово уходит в исключения (самообучение)
        if let typed = lastAutoTyped, translate(strokes, via: other) == typed {
            exceptionsFile.add(typed)
            lastAutoTyped = nil
            log("«\(typed)» добавлено в исключения")
            showPill(text: "искл.", color: .systemGray)
        }

        log("двойной Shift: «\(currentSource().map { translate(strokes, via: $0) } ?? "")» -> «\(translate(strokes, via: other))»")
        performReplace(strokes: strokes, trailingSpaces: trailing, to: other)
        wordBuffer.removeAll()
        lastWord = strokes
        lastWordTrailing = trailing
    }

    // Тройной Shift: набранный ключ заменяется текстом из словаря вставок
    func expandSnippet() {
        guard !wordBuffer.isEmpty, let cur = currentSource() else {
            log("Cmd+Option+0: ключ не набран")
            return
        }
        let typed = translate(wordBuffer, via: cur)
        var value = snippetsFile.value(for: typed)
        if value == nil, let other = otherLayout() {
            // ключ мог быть набран не в той раскладке
            value = snippetsFile.value(for: translate(wordBuffer, via: other))
        }
        guard let text = value else {
            log("Cmd+Option+0: нет вставки для «\(typed)»")
            showPill(text: "нет «\(typed)»", color: .systemGray)
            return
        }
        log("вставка по ключу «\(typed)»")
        let count = wordBuffer.count
        wordBuffer.removeAll()
        lastWord = nil
        replaceWithText(backspaces: count, text: text)
    }

    func insertSlot(_ number: Int) {
        guard let text = snippetsFile.value(for: String(number)) else {
            log("слот \(number): пусто")
            return
        }
        log("вставка из слота \(number)")
        replaceWithText(backspaces: 0, text: text)
    }

    // Конвертация выделенного текста через Универсальный доступ, запасной путь — буфер обмена
    func convertSelection() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let f = focusedRef, CFGetTypeID(f) == AXUIElementGetTypeID() else { return false }
        let element = f as! AXUIElement

        var selRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selRef) == .success,
              let selected = selRef as? String, !selected.isEmpty else { return false }

        guard let (converted, target) = convertText(selected), converted != selected else { return false }

        if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, converted as CFTypeRef) == .success {
            TISSelectInputSource(target)
            return true
        }

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(converted, forType: .string)
        DispatchQueue.global(qos: .userInteractive).async {
            self.postKey(9, flags: .maskCommand)  // Cmd+V
            usleep(150000)
            DispatchQueue.main.async {
                TISSelectInputSource(target)
                if let saved {
                    pb.clearContents()
                    pb.setString(saved, forType: .string)
                }
            }
        }
        return true
    }

    func convertText(_ text: String) -> (String, TISInputSource)? {
        let layouts = enabledLayouts()
        guard layouts.count > 1 else { return nil }
        var cyr = 0, lat = 0
        for ch in text.unicodeScalars {
            if ch.value >= 0x0400 && ch.value <= 0x04FF { cyr += 1 }
            else if (ch.value >= 0x41 && ch.value <= 0x5A) || (ch.value >= 0x61 && ch.value <= 0x7A) { lat += 1 }
        }
        guard cyr + lat > 0 else { return nil }
        let wantLang = cyr > lat ? "en" : "ru"
        guard let target = layouts.first(where: { sourceLang($0).hasPrefix(wantLang) }),
              let from = layouts.first(where: { sourceID($0) != sourceID(target) }) else { return nil }
        let map = charMap(from: from, to: target)
        return (String(text.map { map[$0] ?? $0 }), target)
    }

    // MARK: Синтетический ввод

    func postKey(_ keycode: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMagic)
            e.post(tap: .cgSessionEventTap)
            usleep(1200)
        }
    }

    // Вставка через буфер обмена: синтетические Unicode-события игнорируются
    // Electron-приложениями (Claude, Termius, VS Code), а Cmd+V понимают все
    func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        postKey(9, flags: .maskCommand)  // Cmd+V
        usleep(200000)
        DispatchQueue.main.async {
            guard let savedString else { return }
            pb.clearContents()
            pb.setString(savedString, forType: .string)
        }
    }

    func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        return false
    }

    func replaceWithText(backspaces: Int, text: String) {
        guard !replaceInProgress, ensureAccessibility() else { return }
        replaceInProgress = true
        DispatchQueue.global(qos: .userInteractive).async {
            for _ in 0..<backspaces { self.postKey(51) }
            if backspaces > 0 { usleep(20000) }
            self.pasteText(text)
            DispatchQueue.main.async { self.replaceInProgress = false }
        }
    }

    func performReplace(strokes: [Stroke], trailingSpaces: Int, to target: TISInputSource) {
        guard !replaceInProgress, ensureAccessibility() else { return }
        replaceInProgress = true
        let total = strokes.count + trailingSpaces
        DispatchQueue.global(qos: .userInteractive).async {
            for _ in 0..<total { self.postKey(51) }
            usleep(20000)
            DispatchQueue.main.sync { _ = TISSelectInputSource(target) }
            usleep(50000)  // даём раскладке примениться
            for s in strokes {
                var flags: CGEventFlags = []
                if s.shift { flags.insert(.maskShift) }
                if s.caps { flags.insert(.maskAlphaShift) }
                self.postKey(s.keycode, flags: flags)
            }
            for _ in 0..<trailingSpaces { self.postKey(49) }
            DispatchQueue.main.async { self.replaceInProgress = false }
        }
    }

    // MARK: Горячие клавиши слотов (Cmd+Option+1...9)

    func registerSlotHotkeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                if hkID.id == 0 { me.expandSnippet() } else { me.insertSlot(Int(hkID.id)) }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        // Cmd+Option+0 разворачивает набранный ключ, Cmd+Option+1...9 — слоты
        var failed: [String] = []
        let digitKeycodes: [UInt32] = [expandKeycode, 18, 19, 20, 21, 23, 22, 26, 28, 25]  // 0...9
        for (index, keycode) in digitKeycodes.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4C474C4F), id: UInt32(index))
            let status = RegisterEventHotKey(keycode, UInt32(cmdKey | optionKey), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr { failed.append("\(index)") }
            hotKeyRefs.append(ref)
        }
        if !failed.isEmpty { log("не удалось занять Cmd+Option+: \(failed.joined(separator: ", "))") }
    }

    // MARK: Обновления

    func checkForUpdates(manual: Bool) {
        guard let url = URL(string: releasesAPI) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if manual {
                    DispatchQueue.main.async {
                        self.alert("Не удалось проверить обновления",
                                   "Страница релизов недоступна. Возможно, нет сети или репозиторий закрыт.")
                    }
                }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let newer = latest.compare(current, options: .numeric) == .orderedDescending
            let assets = json["assets"] as? [[String: Any]] ?? []
            let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            let dmgURL = dmg?["browser_download_url"] as? String

            DispatchQueue.main.async {
                if !newer {
                    if manual { self.alert("Обновлений нет", "Установлена последняя версия \(current).") }
                    return
                }
                let ok = self.confirm("Доступна версия \(latest)",
                                      "Установлена \(current). Обновить сейчас? Приложение перезапустится.")
                if ok, let dmgURL { self.downloadAndInstall(dmgURL) }
                else if ok { NSWorkspace.shared.open(URL(string: releasesPage)!) }
            }
        }.resume()
    }

    func downloadAndInstall(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        log("загрузка обновления: \(urlString)")
        URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, error in
            guard let self else { return }
            guard let tmp, error == nil else {
                DispatchQueue.main.async { self.alert("Не удалось скачать обновление", error?.localizedDescription ?? "") }
                return
            }
            let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("LayoutGlow-update.dmg")
            try? FileManager.default.removeItem(at: dmg)
            try? FileManager.default.moveItem(at: tmp, to: dmg)

            let script = """
            set -e
            MP=$(mktemp -d)
            hdiutil attach -nobrowse -quiet -mountpoint "$MP" "\(dmg.path)"
            rm -rf "/Applications/LayoutGlow.app"
            cp -R "$MP/LayoutGlow.app" /Applications/
            hdiutil detach -quiet "$MP" || true
            rm -f "\(dmg.path)"
            sleep 1
            open -a /Applications/LayoutGlow.app
            """
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("layoutglow-update.sh")
            try? script.write(to: path, atomically: true, encoding: .utf8)

            DispatchQueue.main.async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments = [path.path]
                do {
                    try task.run()
                    NSApp.terminate(nil)
                } catch {
                    self.alert("Не удалось установить обновление", error.localizedDescription)
                }
            }
        }.resume()
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    func confirm(_ title: String, _ text: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "Обновить")
        a.addButton(withTitle: "Позже")
        return a.runModal() == .alertFirstButtonReturn
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
