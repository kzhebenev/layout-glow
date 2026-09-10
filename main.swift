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
let lineKeycode: UInt32 = 27     // Cmd+Option+минус — конвертировать строку
let slotKeycodes: Set<Int64> = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25, 27]  // цифры и минус
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
            "iCloudSync": false,
            "onboarded": false,
            "perFieldLayout": false,
            "backspaceUndo": false,
            "dryRun": false,
            "clipboardHistory": true,
            "allowedApps": ["com.termius.mac"],
            "appModes": [String: String](),
            "fieldLayouts": [String: String](),
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
    var iCloudSync: Bool {
        get { d.bool(forKey: "iCloudSync") }
        set { d.set(newValue, forKey: "iCloudSync") }
    }
    var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }
    var clipboardHistory: Bool {
        get { d.bool(forKey: "clipboardHistory") }
        set { d.set(newValue, forKey: "clipboardHistory") }
    }
    var dryRun: Bool {
        get { d.bool(forKey: "dryRun") }
        set { d.set(newValue, forKey: "dryRun") }
    }
    // Приложения, где исправление разрешено явно: перевешивает
    // автоматическое определение терминала
    var allowedApps: Set<String> {
        get { Set(d.stringArray(forKey: "allowedApps") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "allowedApps") }
    }
    var appModes: [String: String] {
        get { d.dictionary(forKey: "appModes") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "appModes") }
    }
    var backspaceUndo: Bool {
        get { d.bool(forKey: "backspaceUndo") }
        set { d.set(newValue, forKey: "backspaceUndo") }
    }
    var perFieldLayout: Bool {
        get { d.bool(forKey: "perFieldLayout") }
        set { d.set(newValue, forKey: "perFieldLayout") }
    }
    var fieldLayouts: [String: String] {
        get { d.dictionary(forKey: "fieldLayouts") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "fieldLayouts") }
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let b = bundleID else { return false }
        return excludedApps.contains(b)
    }
    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        var s = excludedApps
        var allowed = allowedApps
        if excluded {
            s.insert(bundleID)
            allowed.remove(bundleID)
        } else {
            s.remove(bundleID)
            allowed.insert(bundleID)   // явное разрешение сильнее автоопределения
        }
        excludedApps = s
        allowedApps = allowed
    }
}

// Что вернуть, если сразу после автоисправления нажат Backspace
struct PendingUndo {
    let corrected: String     // что оказалось в тексте
    let original: String      // что было набрано
    let word: String          // слово для списка исключений
    let layoutID: String      // раскладка, в которой набирали
    let bundleID: String?
    let at: TimeInterval
}

let undoWindow = 2.0          // сколько секунд Backspace считается откатом
let terminalMinWordLength = 4  // в оболочке «b» и «yj» — аргументы команд, а не опечатки
let typingGuard = 1.5         // столько секунд после нажатия раскладку не трогаем
let autoSwitchCooldown = 3.0  // и не переключаем автоматически чаще, чем раз в столько

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
    var axObserver: AXObserver?
    var observedPid: pid_t = 0
    var hotkeyHandlerInstalled = false

    var exceptionsFile = WordFile(name: "exceptions.txt", header: exceptionsHeader,
                                  directory: dictionaryDirectory(iCloud: Settings.shared.iCloudSync))
    var commandsFile = WordFile(name: "commands.txt", header: commandsHeader, defaults: defaultCommands,
                                directory: dictionaryDirectory(iCloud: Settings.shared.iCloudSync))
    var snippetsFile = SnippetFile(name: "snippets.txt", header: "", defaults: defaultSnippets,
                                   directory: dictionaryDirectory(iCloud: Settings.shared.iCloudSync))
    var rulesFile = SnippetFile(name: "layout-rules.txt", header: "", defaults: defaultLayoutRules,
                                directory: dictionaryDirectory(iCloud: Settings.shared.iCloudSync))
    var hotkeysFile = SnippetFile(name: "hotkeys.txt", header: "", defaults: defaultHotkeys,
                                  directory: dictionaryDirectory(iCloud: Settings.shared.iCloudSync))
    var presetsFile = SnippetFile(name: "presets.txt", header: "", defaults: defaultPresets,
                                  directory: dictionaryDirectory(iCloud: Settings.shared.iCloudSync))
    var clipboard: ClipboardHistory?
    var lastFieldKey = ""
    var secureFieldCached = false
    var clipboardBackup: String?
    var inputTick = 0            // растёт на каждом настоящем нажатии
    var slowTick = 0
    var lastInputAt: TimeInterval = 0
    var lastAutoSwitchAt: TimeInterval = 0
    var lastStatusText = ""
    var corrections: [String] = []
    var pausedForSmoke = false
    var verifyArmed = false
    var pendingUndo: PendingUndo?
    // Нажатия после границы слова. Храним именно нажатия, а не буквы:
    // если исправление меняет раскладку, эти клавиши тоже нужно
    // прочитать по-новому, иначе «z 'njuj» даёт «я 'nого»
    var typedAfterBoundary: [Stroke] = []
    var correctionTick = 0
    var onboardingWindow: NSWindow?
    var shortcutsWindow: NSWindow?
    var onboardingTimer: Timer?
    var smoke: SmokeTest?
    var preferences: PreferencesWindow?

    // Диагностика
    var keysSeen = 0
    var shiftTaps = 0
    var events: [String] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        if !smokeMode, Bundle.main.bundlePath.hasSuffix(".app"),
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

        // Отладочные триггеры: показать ярлык или окно справки без меню
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(testDot),
            name: NSNotification.Name("ru.devkz.layoutglow.testdot"),
            object: nil, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showOnboardingFromMenu),
            name: NSNotification.Name("ru.devkz.layoutglow.setup"),
            object: nil, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(snapshotWindows),
            name: NSNotification.Name("ru.devkz.layoutglow.snapshot"),
            object: nil, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showPreferences),
            name: NSNotification.Name("ru.devkz.layoutglow.prefs"),
            object: nil, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showShortcuts),
            name: NSNotification.Name("ru.devkz.layoutglow.shortcuts"),
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
                self.observeFocus(for: app)
                self.focusChanged()
                self.restoreLayout(for: app)
            }
            self.wordBuffer.removeAll()
            self.lastWord = nil
            self.typedAfterBoundary.removeAll()
        }

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = currentLayout()
            if now != self.lastLayout { self.apply(layout: now, animated: true) }
            self.exceptionsFile.reload()
            self.commandsFile.reload()
            self.snippetsFile.reload()
            self.rulesFile.reload()
            self.presetsFile.reload()
            if self.hotkeysFile.reloadIfChanged() { self.registerSlotHotkeys() }
            // Запасная проверка на случай, если уведомление о фокусе не пришло
            self.slowTick &+= 1
            if self.slowTick % 6 == 0 {
                if Settings.shared.perFieldLayout { self.checkFocusedField() }
                self.secureFieldCached = self.isSecureFieldFocused()
            }
        }

        loadCorrections()
        clipboard = ClipboardHistory(delegate: self)
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.clipboard?.check() }
        migrateTerminalModes()
        ensureDefaultHotkeys()
        startTap()
        registerSlotHotkeys()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.4)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.writeStatus() }
        writeStatus()

        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            // Через полминуты без доступа показываем окно с кнопкой ремонта:
            // молча ждать бесполезно, человек уже поставил галочку
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                guard !AXIsProcessTrusted() else { return }
                self.log("доступ так и не выдан — показываю окно настройки")
                self.showOnboarding(activate: false)
            }
        }
        if smokeMode {
            log("режим дымовых тестов")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.smoke = SmokeTest(delegate: self)
                self.smoke?.run()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.checkForUpdates(manual: false) }
        armPostUpdateCheck()
        if !Settings.shared.onboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showOnboarding(activate: false) }
        }
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
        rememberFieldLayout()
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
        statusItem?.button?.attributedTitle = NSAttributedString(string: style.label, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: style.color,
        ])
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

    // Поле для пароля: правка текста в нём недопустима — под звёздочками
    // не видно, что произошло, и пароль молча портится. Нативные поля даёт
    // secure input, веб-поля определяются по подроли и подсказкам
    func isSecureFieldFocused() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard let element = focusedElement() else { return false }
        func attribute(_ name: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
            return ref as? String
        }
        if attribute(kAXSubroleAttribute as String) == "AXSecureTextField" { return true }
        let hints = [kAXRoleDescriptionAttribute as String, kAXPlaceholderValueAttribute as String,
                     kAXTitleAttribute as String, kAXDescriptionAttribute as String]
        for name in hints {
            guard let value = attribute(name)?.lowercased() else { continue }
            if value.contains("secure") || value.contains("password") || value.contains("пароль") { return true }
        }
        return false
    }

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
    // Подписка на смену фокуса: опрос раз в полсекунды и запаздывал,
    // и зря будил систему. Уведомление приходит сразу
    func observeFocus(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, pid != observedPid else { return }
        if let old = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
        }
        axObserver = nil
        observedPid = 0

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { me.focusChanged() }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        let status = AXObserverAddNotification(observer, element,
                                               kAXFocusedUIElementChangedNotification as CFString,
                                               Unmanaged.passUnretained(self).toOpaque())
        guard status == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        observedPid = pid
    }

    @objc func focusChanged() {
        secureFieldCached = isSecureFieldFocused()
        // Electron и терминалы шлют уведомления о фокусе пачками прямо
        // во время печати. Сбрасывать набранное на каждое — значит рвать
        // слово пополам: так «1ю8ю6ю» превращалось в «ю8ю6ю» и не чинилось
        // В Termius и Electron роль поля то отдаётся, то нет. Считать
        // это сменой поля нельзя: слово рвётся и не чинится
        let key = focusedFieldKey()
        if let key, !lastFieldKey.isEmpty, key != lastFieldKey {
            wordBuffer.removeAll()
            lastWord = nil
            pendingUndo = nil
            typedAfterBoundary.removeAll()
        }
        if Settings.shared.perFieldLayout { checkFocusedField() }
        else if let key { lastFieldKey = key }
    }

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
        guard let bid = app.bundleIdentifier else { return }
        // Правило из файла сильнее запомненного: «в терминале всегда EN»
        if let lang = rulesFile.value(for: bid), let source = source(forLanguage: lang) {
            select(source, why: "правило для «\(appName(for: bid))»: \(lang)")
            return
        }
        guard Settings.shared.perAppLayout,
              let wanted = Settings.shared.appLayouts[bid],
              let source = layout(withID: wanted) else { return }
        select(source, why: "раскладка для «\(appName(for: bid))»")
    }

    func source(forLanguage code: String) -> TISInputSource? {
        let wanted = code.trimmingCharacters(in: .whitespaces).lowercased()
        return enabledLayouts().first { sourceLang($0).lowercased().hasPrefix(wanted) }
    }

    // Автоматическое переключение не должно влезать в набор: раньше
    // смена роли поля посреди слова уводила раскладку, и «хочу»
    // превращалось в «[очу»
    func select(_ source: TISInputSource, why: String) {
        guard sourceID(source) != currentLayoutFullID() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastInputAt < typingGuard || !wordBuffer.isEmpty {
            log("\(why): отложено, идёт набор")
            rememberFieldLayout()   // подстраиваемся под то, что человек печатает сейчас
            return
        }
        guard now - lastAutoSwitchAt > autoSwitchCooldown else {
            log("\(why): пропущено, только что переключали")
            return
        }
        lastAutoSwitchAt = now
        restoringLayout = true
        TISSelectInputSource(source)
        log(why)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.restoringLayout = false }
    }

    // MARK: Раскладка по типу поля (адресная строка, поиск, текст)

    // Ключ вида «com.apple.Safari:AXTextField:AXSearchField»
    func focusedFieldKey() -> String? {
        guard let element = focusedElement(), let bid = frontApp?.bundleIdentifier else { return nil }
        func attribute(_ name: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
            return ref as? String
        }
        guard let role = attribute(kAXRoleAttribute as String) else { return nil }
        let subrole = attribute(kAXSubroleAttribute as String) ?? ""
        // AXTextField и AXTextArea в Electron подменяют друг друга у одного
        // и того же поля, поэтому считаем их одной ролью
        let normalized = (role == "AXTextArea" || role == "AXTextField") ? "AXText" : role
        return "\(bid):\(normalized)\(subrole.isEmpty ? "" : ":" + subrole)"
    }

    func checkFocusedField() {
        guard let key = focusedFieldKey(), key != lastFieldKey else { return }
        lastFieldKey = key
        guard let wanted = Settings.shared.fieldLayouts[key], let source = layout(withID: wanted) else { return }
        select(source, why: "раскладка для поля \(key.components(separatedBy: ":").dropFirst().joined(separator: ":"))")
    }

    func rememberFieldLayout() {
        guard Settings.shared.perFieldLayout, !restoringLayout, let key = focusedFieldKey() else { return }
        var map = Settings.shared.fieldLayouts
        map[key] = currentLayoutFullID()
        Settings.shared.fieldLayouts = map
        lastFieldKey = key
    }

    // MARK: Диагностика

    func log(_ line: String) {
        events.append(line)
        if events.count > 40 { events.removeFirst(events.count - 40) }
        writeStatus()
    }

    // История исправлений: последние строки живут долго, в отличие от
    // сорока событий в status.log, которые вытесняются за минуту
    func recordCorrection(_ line: String) {
        let path = runtimeDirectory().appendingPathComponent("corrections.log")
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let app = frontApp?.localizedName ?? "?"
        corrections.append("\(stamp)  [\(app)]  \(line)")
        if corrections.count > 500 { corrections.removeFirst(corrections.count - 500) }
        try? corrections.joined(separator: "\n").appending("\n").write(to: path, atomically: true, encoding: .utf8)
    }

    func loadCorrections() {
        let path = runtimeDirectory().appendingPathComponent("corrections.log")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return }
        corrections = text.split(separator: "\n").map(String.init).suffix(500).map { $0 }
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
        правил раскладки: \(rulesFile.items.count), сочетаний занято: \(hotKeyRefs.count)
        раскладка по типу поля: \(Settings.shared.perFieldLayout ? "вкл" : "выкл"), поле: \(lastFieldKey.isEmpty ? "—" : lastFieldKey)
        раскладка по приложениям: \(Settings.shared.perAppLayout ? "вкл" : "выкл")

        события:
        """
        text += "\n" + events.joined(separator: "\n") + "\n"
        // Пишем только когда что-то изменилось: файл раз в две секунды
        // впустую крутил диск и будил систему
        guard text != lastStatusText else { return }
        lastStatusText = text
        try? text.write(to: runtimeDirectory().appendingPathComponent("status.log"),
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

    // Терминал определяется по признакам, а не по списку: новые
    // эмуляторы появляются, а поведение в них нужно осторожное
    static let terminalHints = ["term", "console", "shell", "ssh", "putty", "iterm",
                                "warp", "kitty", "ghostty", "tabby", "alacritty", "hyper"]

    // По идентификатору: работает и для приложений, которые сейчас не запущены
    func isTerminalLike(bundleID: String) -> Bool {
        let identity = (bundleID + " " + appName(for: bundleID)).lowercased()
        return AppDelegate.terminalHints.contains(where: { identity.contains($0) })
    }

    func isTerminalLike(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        let identity = ((app.bundleIdentifier ?? "") + " " + (app.localizedName ?? "")).lowercased()
        if AppDelegate.terminalHints.contains(where: { identity.contains($0) }) { return true }
        guard let element = focusedElement() else { return false }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &ref) == .success,
              let description = ref as? String else { return false }
        let lowered = description.lowercased()
        return lowered.contains("terminal") || lowered.contains("терминал")
            || lowered.contains("console") || lowered.contains("консоль")
    }

    // Режим приложения: полностью, только вручную (жесты работают,
    // автоисправление молчит) или выключено. Терминалы по умолчанию
    // получают «только вручную»: в оболочке слова вроде «b» и «yj» —
    // это аргументы команд, а не опечатки, и правка там портит ввод
    enum AppMode: String {
        case full = "полностью"
        case manual = "вручную"
        case off = "выключено"
    }

    func mode(for app: NSRunningApplication?) -> AppMode {
        guard let bid = app?.bundleIdentifier else { return .full }
        if let stored = Settings.shared.appModes[bid], let mode = AppMode(rawValue: stored) { return mode }
        if Settings.shared.allowedApps.contains(bid) { return .full }
        if Settings.shared.excludedApps.contains(bid) { return .off }
        return isTerminalLike(app) ? .manual : .full
    }

    // Режим приложения, которое сейчас не запущено: по сохранённому выбору
    // и признакам в идентификаторе
    func mode(forBundleID bid: String) -> AppMode {
        if let stored = Settings.shared.appModes[bid], let mode = AppMode(rawValue: stored) { return mode }
        if Settings.shared.allowedApps.contains(bid) { return .full }
        if Settings.shared.excludedApps.contains(bid) { return .off }
        return isTerminalLike(bundleID: bid) ? .manual : .full
    }

    func setMode(_ mode: AppMode, for bundleID: String) {
        var modes = Settings.shared.appModes
        modes[bundleID] = mode.rawValue
        Settings.shared.appModes = modes
        var excluded = Settings.shared.excludedApps
        var allowed = Settings.shared.allowedApps
        excluded.remove(bundleID)
        allowed.remove(bundleID)
        Settings.shared.excludedApps = excluded
        Settings.shared.allowedApps = allowed
    }

    func nextMode(after mode: AppMode) -> AppMode {
        switch mode {
        case .full: return .manual
        case .manual: return .off
        case .off: return .full
        }
    }

    func correctionAllowed(in app: NSRunningApplication?) -> Bool { mode(for: app) == .full }
    func manualAllowed(in app: NSRunningApplication?) -> Bool { mode(for: app) != .off }

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

        func header(_ text: String) {
            let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            i.attributedTitle = NSAttributedString(string: text.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 0.6,
            ])
            i.isEnabled = false
            menu.addItem(i)
        }
        func symbol(_ name: String) -> NSImage? {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image?.isTemplate = true
            return image
        }
        func toggle(_ title: String, _ on: Bool, _ selector: Selector, icon: String) {
            let i = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            i.state = on ? .on : .off
            i.target = self
            i.image = symbol(icon)
            menu.addItem(i)
        }
        func action(_ title: String, _ selector: Selector, icon: String? = nil,
                    into target: NSMenu? = nil, tooltip: String? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            i.target = self
            i.toolTip = tooltip
            if let icon { i.image = symbol(icon) }
            (target ?? menu).addItem(i)
            return i
        }

        // Текущее состояние крупно и в цвет раскладки
        let style = currentStyle()
        let layoutName = currentSource().map { sourceName($0) } ?? "—"
        let state = NSMenuItem(title: layoutName, action: nil, keyEquivalent: "")
        let line = NSMutableAttributedString(string: style.label + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: style.color,
        ])
        line.append(NSAttributedString(string: layoutName, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ]))
        state.attributedTitle = line
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())

        header("Переключение")
        toggle("Быстрый тап Fn", s.fnSwitch, #selector(toggleFn), icon: "bolt")
        toggle("Своя раскладка для приложений", s.perAppLayout, #selector(togglePerApp), icon: "square.grid.2x2")
        toggle("Раскладка по типу поля", s.perFieldLayout, #selector(togglePerField), icon: "text.cursor")

        header("Исправление")
        toggle("Автоисправление раскладки", s.autoCorrect, #selector(toggleAuto), icon: "wand.and.stars")
        toggle("Конвертация по двойному Shift", s.manualConvert, #selector(toggleManual), icon: "arrow.2.squarepath")
        toggle("Откат исправления по Backspace", s.backspaceUndo, #selector(toggleBackspaceUndo), icon: "delete.left")
        toggle("Только показывать, не менять текст", s.dryRun, #selector(toggleDryRun), icon: "eye")
        if let app = frontApp, let bid = app.bundleIdentifier {
            let name = app.localizedName ?? appName(for: bid)
            let current = mode(for: app)
            let mark = isTerminalLike(app) ? ", терминал" : ""
            let item = action("«\(name)»: \(current.rawValue)\(mark)", #selector(toggleFrontApp),
                              icon: "app.badge.checkmark",
                              tooltip: "Нажмите, чтобы переключить: полностью, вручную, выключено")
            item.state = current == .full ? .on : (current == .manual ? .mixed : .off)
        }
        let excluded = s.excludedApps.filter { isInstalled($0) }.sorted { appName(for: $0) < appName(for: $1) }
        if !excluded.isEmpty {
            let head = action("Выключено в приложениях (\(excluded.count))", #selector(doNothing), icon: "nosign")
            let sub = NSMenu()
            for bid in excluded {
                let i = NSMenuItem(title: appName(for: bid), action: #selector(removeExcludedApp(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = bid
                i.toolTip = "\(bid) — включить исправление здесь"
                sub.addItem(i)
            }
            menu.setSubmenu(sub, for: head)
        }

        if let history = clipboard, !history.items.isEmpty {
            let head = action("Буфер обмена (\(history.items.count))", #selector(doNothing), icon: "doc.on.clipboard")
            let sub = NSMenu()
            for (index, entry) in history.items.prefix(12).enumerated() {
                let line = entry.replacingOccurrences(of: "\n", with: " ")
                let short = line.count > 48 ? String(line.prefix(48)) + "…" : line
                let item = NSMenuItem(title: short, action: #selector(pasteHistoryItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = index
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let all = NSMenuItem(title: "Показать всё…", action: #selector(showClipboardPanel), keyEquivalent: "")
            all.target = self
            sub.addItem(all)
            menu.setSubmenu(sub, for: head)
        }
        let presets = (1...10).compactMap { n -> (Int, String)? in
            presetsFile.value(for: String(n)).map { (n, $0) }
        }
        if !presets.isEmpty {
            let head = action("Пресеты (\(presets.count))", #selector(doNothing), icon: "text.badge.plus")
            let sub = NSMenu()
            for (number, value) in presets {
                let short = value.count > 44 ? String(value.prefix(44)) + "…" : value
                let item = NSMenuItem(title: "\(number) — \(short)", action: #selector(insertPresetItem(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = number
                item.toolTip = hotkeysFile.value(for: "пресет-\(number)") ?? ""
                sub.addItem(item)
            }
            menu.setSubmenu(sub, for: head)
        }

        menu.addItem(.separator())
        let preferencesItem = NSMenuItem(title: "Настройки…", action: #selector(showPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        preferencesItem.image = symbol("gearshape")
        menu.addItem(preferencesItem)
        _ = action("Справка по сочетаниям…", #selector(showShortcuts), icon: "questionmark.circle")

        menu.addItem(.separator())
        let inputOK = eventTap != nil
        let axOK = AXIsProcessTrusted()
        if !inputOK || !axOK {
            let warn = action("Нужны разрешения — открыть настройку",
                              #selector(showOnboardingFromMenu), icon: "exclamationmark.triangle")
            warn.attributedTitle = NSAttributedString(
                string: "Нужны разрешения — открыть настройку",
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                             .foregroundColor: NSColor.systemOrange])
        } else {
            _ = action("Разрешения выданы", #selector(showOnboardingFromMenu), icon: "checkmark.seal",
                       tooltip: "Открыть окно настройки")
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        _ = action("Версия \(version) — проверить обновления", #selector(checkUpdatesManually), icon: "arrow.down.circle")
        let copyright = NSMenuItem(title: "© 2026 Константин Жебенев, лицензия MIT", action: nil, keyEquivalent: "")
        copyright.attributedTitle = NSAttributedString(
            string: "© 2026 Константин Жебенев, лицензия MIT",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.tertiaryLabelColor])
        copyright.isEnabled = false
        menu.addItem(copyright)
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = symbol("power")
        menu.addItem(quit)
    }

    @objc func doNothing() {}

    @objc func pasteHistoryItem(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        clipboard?.paste(index)
    }

    @objc func showClipboardPanel() { clipboard?.togglePanel() }

    @objc func insertPresetItem(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? Int else { return }
        insertPreset(number)
    }

    @objc func toggleFn() { Settings.shared.fnSwitch.toggle() }
    @objc func toggleAuto() { Settings.shared.autoCorrect.toggle() }
    @objc func toggleManual() { Settings.shared.manualConvert.toggle() }
    @objc func toggleBackspaceUndo() { Settings.shared.backspaceUndo.toggle() }
    @objc func toggleDryRun() { Settings.shared.dryRun.toggle() }
    @objc func togglePerApp() {
        Settings.shared.perAppLayout.toggle()
        if Settings.shared.perAppLayout { rememberLayout() }
    }
    @objc func toggleCaps() { Settings.shared.capsGlow.toggle(); refreshGlow(animated: false) }
    @objc func toggleCaret() { Settings.shared.caretDot.toggle() }
    @objc func togglePerField() {
        Settings.shared.perFieldLayout.toggle()
        lastFieldKey = ""
        if Settings.shared.perFieldLayout { rememberFieldLayout() }
    }
    @objc func toggleFrontApp() {
        guard let bid = frontApp?.bundleIdentifier else { return }
        let next = nextMode(after: mode(for: frontApp))
        setMode(next, for: bid)
        showPill(text: next.rawValue, color: .systemGray)
    }
    @objc func removeExcludedApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        Settings.shared.setExcluded(bid, false)
    }
    @objc func openExceptions() { NSWorkspace.shared.open(exceptionsFile.url) }
    @objc func openCommands() { NSWorkspace.shared.open(commandsFile.url) }
    @objc func openSnippets() { NSWorkspace.shared.open(snippetsFile.url) }
    @objc func openRules() { NSWorkspace.shared.open(rulesFile.url) }
    @objc func openHotkeys() { NSWorkspace.shared.open(hotkeysFile.url) }
    @objc func openCorrections() {
        NSWorkspace.shared.open(runtimeDirectory().appendingPathComponent("corrections.log"))
    }
    @objc func reloadDictionaries() {
        exceptionsFile.reload(force: true)
        commandsFile.reload(force: true)
        snippetsFile.reload(force: true)
        rulesFile.reload(force: true)
        hotkeysFile.reload(force: true)
        registerSlotHotkeys()
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
        if pausedForSmoke { return }

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            wordBuffer.removeAll(); lastWord = nil; typedAfterBoundary.removeAll()
            return
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown {
            inputTick &+= 1
            lastInputAt = ProcessInfo.processInfo.systemUptime
        }
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
        // Пока идёт замена, набранное копим отдельно: иначе наши backspace
        // съедят эти буквы, и получится «рвер hb» вместо «сервер»
        if replaceInProgress {
            if keycode == 51 {
                if !typedAfterBoundary.isEmpty { typedAfterBoundary.removeLast() }
            } else if let cur = currentSource() {
                let stroke = Stroke(keycode: CGKeyCode(keycode), shift: event.flags.contains(.maskShift),
                                    caps: event.flags.contains(.maskAlphaShift))
                if translate([stroke], via: cur).count == 1 { typedAfterBoundary.append(stroke) }
            }
            return
        }
        guard Settings.shared.autoCorrect || Settings.shared.manualConvert else { return }
        if IsSecureEventInputEnabled() || secureFieldCached { wordBuffer.removeAll(); lastWord = nil; return }
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
            pendingUndo = nil
            let word = wordBuffer
            wordBuffer.removeAll()
            if !word.isEmpty {
                lastWord = word
                lastWordTrailing = 1
                typedAfterBoundary.removeAll()
                if Settings.shared.autoCorrect { DispatchQueue.main.async { self.autoCorrect(word) } }
            } else if lastWord != nil {
                lastWordTrailing = min(lastWordTrailing + 1, 4)
            }
        case 51:  // backspace
            // Сразу после автоисправления Backspace означает «верни как было»
            if Settings.shared.backspaceUndo, let undo = pendingUndo, undoIsFresh(undo) {
                pendingUndo = nil
                undoAutoCorrection(undo)
                return
            }
            pendingUndo = nil
            if wordBuffer.isEmpty { lastWord = nil } else { wordBuffer.removeLast() }
        case 36, 76, 48, 53, 117, 115, 116, 119, 121, 123, 124, 125, 126:
            wordBuffer.removeAll(); lastWord = nil; typedAfterBoundary.removeAll()
        default:
            let stroke = Stroke(keycode: CGKeyCode(keycode), shift: flags.contains(.maskShift),
                                caps: flags.contains(.maskAlphaShift))
            guard let cur = currentSource() else { return }
            let produced = translate([stroke], via: cur)
            guard let char = produced.first, produced.count == 1 else { return }
            keysSeen += 1

            // Знаки вроде запятой заканчивают слово так же, как пробел,
            // но только если в другой раскладке это не буква
            let otherSource = otherLayout()
            let isBoundary = boundaryChars.contains(char)
                && (otherSource.map { punctuationInBothLayouts(stroke, cur, $0) } ?? true)
            if isBoundary {
                let word = wordBuffer
                wordBuffer.removeAll()
                if !word.isEmpty {
                    lastWord = word
                    lastWordTrailing = 1
                    typedAfterBoundary.removeAll()
                    if Settings.shared.autoCorrect {
                        DispatchQueue.main.async { self.autoCorrect(word, boundary: stroke) }
                    }
                }
                return
            }

            // Копим и здесь: буквы, набранные между пробелом и стартом
            // замены, уже в тексте, и стирать их нельзя
            typedAfterBoundary.append(stroke)
            wordBuffer.append(stroke)
            if wordBuffer.count > maxWordLen { wordBuffer.removeAll(); lastWord = nil }
        }
    }

    func autoCorrect(_ word: [Stroke], boundary: Stroke? = nil) {
        guard !word.isEmpty, let cur = currentSource(), let other = otherLayout() else { return }
        guard correctionAllowed(in: frontApp) else {
            log("пропуск: исправление выключено в «\(frontApp?.localizedName ?? "?")»")
            return
        }
        if isSecureFieldFocused() {
            log("пропуск: поле для пароля")
            wordBuffer.removeAll(); lastWord = nil
            return
        }

        let full = translate(word, via: cur)
        // В оболочке однобуквенные и двухбуквенные последовательности —
        // это флаги и аргументы, а не опечатки
        if isTerminalLike(frontApp), full.count < terminalMinWordLength,
           !looksLikeDottedNumber(translate(word, via: other)) {
            log("пропуск «\(full)»: в терминале короткие слова не трогаем")
            return
        }
        if looksTechnical(full) {
            log("пропуск «\(full)»: ссылка, почта или путь")
            return
        }

        // Два прочтения: «всё это слово» и «в конце знаки препинания».
        // Первое важно потому, что «;» и «,» в русской раскладке — буквы «ж» и «б»
        var candidates: [[Stroke]] = [word]
        var stripped = word
        while let last = stripped.last, !(translate([last], via: cur).first?.isLetter ?? false) {
            stripped.removeLast()
        }
        if !stripped.isEmpty && stripped.count != word.count { candidates.append(stripped) }

        var lastReason = "не слово целиком"
        for letters in candidates {
            let typed = translate(letters, via: cur)
            let converted = translate(letters, via: other)
            let decision = correctionDecision(
                typed: typed, converted: converted,
                srcLang: sourceLang(cur), dstLang: sourceLang(other),
                commands: commandsFile.words, exceptions: exceptionsFile.words,
                capsOn: letters.contains(where: { $0.caps }))
            guard decision.correct else {
                lastReason = decision.reason
                continue
            }

            // Хвост знаков и сам знак-граница остаются как набраны:
            // вставляем текст целиком, поэтому переводить их в клавиши не нужно
            let tail = translate(Array(word.dropFirst(letters.count)), via: cur)
            let boundaryText = boundary.map { translate([$0], via: cur) } ?? " "
            log("исправлено «\(typed)» -> «\(converted)»")
            lastAutoTyped = typed
            lastWord = word
            lastWordTrailing = boundaryText.count

            let replacement = converted + tail + boundaryText
            if Settings.shared.dryRun {
                log("сухой прогон: заменил бы «\(typed)» на «\(converted)»")
                showPill(text: converted, color: .systemGray)
                return
            }
            pendingUndo = PendingUndo(corrected: replacement, original: full + boundaryText,
                                      word: typed, layoutID: currentLayoutFullID(),
                                      bundleID: frontApp?.bundleIdentifier,
                                      at: ProcessInfo.processInfo.systemUptime)
            correctionTick = inputTick
            replaceLast(word.count + boundaryText.count, with: replacement,
                        switchTo: other, guardTick: inputTick)
            return
        }
        log("пропуск «\(full)»: \(lastReason)")
    }

    // Откат допустим, только если Backspace — первое нажатие после
    // исправления: иначе он затрёт то, что человек успел напечатать
    func undoIsFresh(_ undo: PendingUndo) -> Bool {
        ProcessInfo.processInfo.systemUptime - undo.at < undoWindow
            && undo.bundleID == frontApp?.bundleIdentifier
            && inputTick == correctionTick + 1
    }

    // Backspace уже съел один символ, поэтому возвращаем остаток.
    // В список исключений слово при этом НЕ попадает: обычное нажатие
    // Backspace слишком легко спутать с намерением «никогда не исправляй»
    func undoAutoCorrection(_ undo: PendingUndo) {
        wordBuffer.removeAll()
        lastWord = nil
        lastAutoTyped = nil
        let remaining = max(0, undo.corrected.count - 1)
        let target = layout(withID: undo.layoutID)
        let tick = inputTick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            self.typedAfterBoundary.removeAll()
            self.replaceLast(remaining, with: undo.original, switchTo: target, guardTick: tick,
                             source: "откат по Backspace")
            self.log("откат по Backspace: «\(undo.word)» возвращено и добавлено в исключения")
            self.showPill(text: "откат", color: .systemGray)
        }
    }

    // MARK: Ручная конвертация и вставки

    func manualConvert() {
        guard manualAllowed(in: frontApp) else {
            log("двойной Shift: выключен в «\(frontApp?.localizedName ?? "?")»")
            return
        }
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
        let text = translate(strokes, via: other) + String(repeating: " ", count: trailing)
        typedAfterBoundary.removeAll()
        replaceLast(strokes.count + trailing, with: text, switchTo: other, source: "двойной Shift")
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

    func insertPreset(_ number: Int) {
        guard let text = presetsFile.value(for: String(number)) else {
            log("пресет \(number): пусто")
            showPill(text: "пресет \(number) пуст", color: .systemGray)
            return
        }
        log("вставка пресета \(number)")
        replaceWithText(backspaces: 0, text: text, source: "пресет \(number)")
    }

    func insertSlot(_ number: Int) {
        guard let text = snippetsFile.value(for: String(number)) else {
            log("слот \(number): пусто")
            return
        }
        log("вставка из слота \(number)")
        replaceWithText(backspaces: 0, text: text, source: "слот \(number)")
    }

    // Конвертация выделенного текста. Accessibility отдаёт выделение далеко
    // не везде (браузеры и Electron — примерно в половине случаев), поэтому
    // при отказе текст берётся через буфер обмена копированием
    func convertSelection() -> Bool {
        if isSecureFieldFocused() {
            log("выделение: поле для пароля, не трогаю")
            return false
        }
        if let (element, selected) = selectionViaAccessibility() {
            guard let (converted, target) = convertText(selected), converted != selected else { return false }
            if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            converted as CFTypeRef) == .success {
                TISSelectInputSource(target)
                log("выделение: заменено напрямую")
                return true
            }
            replaceSelectionByPaste(converted, target: target)
            return true
        }
        guard let selected = selectionViaClipboard() else { return false }
        guard let (converted, target) = convertText(selected), converted != selected else { return false }
        replaceSelectionByPaste(converted, target: target)
        log("выделение: заменено через буфер обмена")
        return true
    }

    func selectionViaAccessibility() -> (AXUIElement, String)? {
        guard AXIsProcessTrusted(), let element = focusedElement() else { return nil }
        var selRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selRef) == .success,
              let selected = selRef as? String, !selected.isEmpty else { return nil }
        return (element, selected)
    }

    // Копируем выделение и ждём, пока изменится счётчик буфера обмена:
    // если он не изменился, значит выделять было нечего
    func selectionViaClipboard() -> String? {
        guard ensureAccessibility() else { return nil }
        let pb = NSPasteboard.general
        let before = pb.changeCount
        clipboardBackup = pb.string(forType: .string)
        postKey(8, flags: .maskCommand)  // Cmd+C
        for _ in 0..<30 {
            usleep(15000)
            if pb.changeCount != before { return pb.string(forType: .string) }
        }
        return nil
    }

    func replaceSelectionByPaste(_ text: String, target: TISInputSource) {
        let pb = NSPasteboard.general
        let saved = clipboardBackup ?? pb.string(forType: .string)
        clipboardBackup = nil
        writeClipboard(text)
        let slow = isTerminalLike(frontApp)
        DispatchQueue.global(qos: .userInteractive).async {
            usleep(slow ? 90000 : 30000)
            self.postKey(9, flags: .maskCommand)  // Cmd+V
            usleep(slow ? 400000 : 260000)
            DispatchQueue.main.async {
                TISSelectInputSource(target)
                self.restoreClipboard(saved)
            }
        }
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
        return (convertTextTokens(text, map: map), target)
    }

    // MARK: Конвертация текущей строки (Cmd+Option+минус)

    func convertLine() {
        if convertLineViaAccessibility() { return }
        // Запасной путь: выделяем строку клавишами и конвертируем как выделение
        guard ensureAccessibility() else { return }
        DispatchQueue.global(qos: .userInteractive).async {
            self.postKey(123, flags: [.maskShift, .maskCommand])  // Shift+Cmd+Влево
            usleep(120000)
            DispatchQueue.main.async {
                if self.convertSelection() {
                    self.log("строка: конвертирована через выделение")
                } else {
                    self.postKey(124, flags: [])  // снимаем выделение
                    self.log("строка: «\(self.frontApp?.localizedName ?? "?")» не отдаёт текст")
                }
            }
        }
    }

    func convertLineViaAccessibility() -> Bool {
        guard let element = focusedElement() else { return false }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty else { return false }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return false }
        var caretRange = CFRange()
        AXValueGetValue(rv as! AXValue, .cfRange, &caretRange)

        let ns = text as NSString
        let caret = min(max(0, caretRange.location), ns.length)
        guard caret > 0 else { return false }
        let before = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: caret))
        let lineStart = before.location == NSNotFound ? 0 : before.location + 1
        guard caret > lineStart else { return false }

        let lineRange = NSRange(location: lineStart, length: caret - lineStart)
        let line = ns.substring(with: lineRange)
        guard let (converted, target) = convertText(line), converted != line else { return false }

        var selection = CFRange(location: lineStart, length: caret - lineStart)
        guard let selValue = AXValueCreate(.cfRange, &selection),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, selValue) == .success,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                           converted as CFTypeRef) == .success else { return false }
        TISSelectInputSource(target)
        log("строка: «\(line)» -> «\(converted)»")
        return true
    }

    // Абзац целиком: от пустой строки до пустой строки вокруг курсора
    @objc func convertParagraph() {
        guard let element = focusedElement() else {
            log("абзац: нет фокуса ввода")
            return
        }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty else {
            log("абзац: «\(frontApp?.localizedName ?? "?")» не отдаёт текст")
            return
        }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else {
            log("абзац: не удалось узнать положение курсора")
            return
        }
        var caretRange = CFRange()
        AXValueGetValue(rv as! AXValue, .cfRange, &caretRange)

        let ns = text as NSString
        let caret = min(max(0, caretRange.location), ns.length)
        let before = ns.range(of: "\n\n", options: .backwards, range: NSRange(location: 0, length: caret))
        let start = before.location == NSNotFound ? 0 : before.location + 2
        let after = ns.range(of: "\n\n", options: [],
                             range: NSRange(location: caret, length: ns.length - caret))
        let end = after.location == NSNotFound ? ns.length : after.location
        guard end > start else { log("абзац: пусто"); return }

        let paragraph = ns.substring(with: NSRange(location: start, length: end - start))
        guard let (converted, target) = convertText(paragraph), converted != paragraph else {
            log("абзац: нечего менять")
            return
        }
        var selection = CFRange(location: start, length: end - start)
        guard let selValue = AXValueCreate(.cfRange, &selection),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, selValue) == .success,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                           converted as CFTypeRef) == .success else {
            log("абзац: приложение не даёт заменить текст")
            return
        }
        TISSelectInputSource(target)
        log("абзац: \(paragraph.count) симв. сконвертировано")
    }

    // MARK: Словари в iCloud

    @objc func toggleICloud() {
        let wanted = !Settings.shared.iCloudSync
        if wanted && iCloudDirectory() == nil {
            alert("iCloud Drive недоступен", "Включите iCloud Drive в системных настройках и попробуйте снова.")
            return
        }
        let from = dictionaryDirectory(iCloud: Settings.shared.iCloudSync)
        let to = dictionaryDirectory(iCloud: wanted)
        for name in ["exceptions.txt", "commands.txt", "snippets.txt", "layout-rules.txt",
                     "hotkeys.txt", "presets.txt"] {
            let src = from.appendingPathComponent(name)
            let dst = to.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            if FileManager.default.fileExists(atPath: dst.path) {
                // На другом маке словарь уже есть: он и остаётся главным
                try? FileManager.default.removeItem(at: src)
            } else {
                try? FileManager.default.moveItem(at: src, to: dst)
            }
        }
        Settings.shared.iCloudSync = wanted
        exceptionsFile = WordFile(name: "exceptions.txt", header: exceptionsHeader, directory: to)
        commandsFile = WordFile(name: "commands.txt", header: commandsHeader,
                                defaults: defaultCommands, directory: to)
        snippetsFile = SnippetFile(name: "snippets.txt", header: "", defaults: defaultSnippets, directory: to)
        rulesFile = SnippetFile(name: "layout-rules.txt", header: "", defaults: defaultLayoutRules, directory: to)
        hotkeysFile = SnippetFile(name: "hotkeys.txt", header: "", defaults: defaultHotkeys, directory: to)
        presetsFile = SnippetFile(name: "presets.txt", header: "", defaults: defaultPresets, directory: to)
        registerSlotHotkeys()
        log("словари: \(wanted ? "в iCloud" : "локально") (\(to.path))")
        showPill(text: wanted ? "iCloud" : "локально", color: .systemGray)
    }

    // MARK: Окно справки

    @objc func showShortcuts() {
        if let w = shortcutsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        func combo(_ action: String, _ fallback: String) -> String {
            (hotkeysFile.value(for: action) ?? fallback).replacingOccurrences(of: "+", with: " + ")
        }
        let rows: [(String, String)] = [
            ("Тап Fn", "Переключить раскладку мгновенно"),
            ("Двойной Shift", "Конвертировать выделенное; без выделения — слово, которое набираешь или набрал последним"),
            ("Двойной Shift после исправления", "Откатить его и занести слово в исключения навсегда"),
            (combo("строка", "cmd+opt+-"), "Конвертировать текущую строку до курсора"),
            (combo("абзац", "cmd+opt+="), "Конвертировать абзац целиком"),
            (combo("ключ", "cmd+opt+0"), "Развернуть набранный ключ в текст из словаря вставок"),
            ("Пробел, запятая, «!», «?»", "Проверяют набранное слово и исправляют раскладку сами"),
        ]
        let slots = (1...9).compactMap { n -> (String, String)? in
            guard let v = snippetsFile.value(for: String(n)) else { return nil }
            let key = (hotkeysFile.value(for: "слот-\(n)") ?? "cmd+opt+\(n)").replacingOccurrences(of: "+", with: " + ")
            return (key, v.count > 46 ? String(v.prefix(46)) + "…" : v)
        }
        let keys = snippetsFile.items
            .filter { Int($0.key) == nil }
            .sorted { $0.key < $1.key }
            .map { ("«\($0.key)» + \(combo("ключ", "cmd+opt+0"))",
                    $0.value.count > 40 ? String($0.value.prefix(40)) + "…" : $0.value) }

        let rowHeight: CGFloat = 34
        let size = NSSize(width: 620, height: CGFloat(rows.count + slots.count + keys.count) * rowHeight + 150)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Сочетания LayoutGlow"
        w.center()
        w.isReleasedWhenClosed = false
        w.level = .floating

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        var y = size.height - 56

        func header(_ text: String) {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 24, y: y, width: size.width - 48, height: 22)
            l.font = .systemFont(ofSize: 14, weight: .semibold)
            content.addSubview(l)
            y -= 30
        }
        func row(_ key: String, _ text: String) {
            let k = NSTextField(labelWithString: key)
            k.frame = NSRect(x: 24, y: y, width: 210, height: 30)
            k.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            k.lineBreakMode = .byTruncatingTail
            content.addSubview(k)

            let v = NSTextField(wrappingLabelWithString: text)
            v.frame = NSRect(x: 244, y: y - 4, width: size.width - 268, height: 34)
            v.font = .systemFont(ofSize: 12)
            v.isEditable = false
            v.drawsBackground = false
            content.addSubview(v)
            y -= rowHeight
        }

        header("Жесты и сочетания")
        for (k, v) in rows { row(k, v) }
        if !slots.isEmpty || !keys.isEmpty {
            y -= 6
            header("Ваши вставки")
            for (k, v) in slots + keys { row(k, v) }
        }

        let edit = NSButton(title: "Открыть словарь вставок", target: self, action: #selector(openSnippets))
        edit.frame = NSRect(x: 24, y: 16, width: 220, height: 28)
        edit.bezelStyle = .rounded
        content.addSubview(edit)

        let close = NSButton(title: "Закрыть", target: self, action: #selector(closeShortcuts))
        close.frame = NSRect(x: size.width - 110, y: 16, width: 86, height: 28)
        close.bezelStyle = .rounded
        content.addSubview(close)

        w.contentView = content
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        shortcutsWindow = w
    }

    @objc func closeShortcuts() {
        shortcutsWindow?.close()
        shortcutsWindow = nil
    }

    // MARK: Окно первого запуска

    @objc func showOnboardingFromMenu() { showOnboarding(activate: true) }

    // При первом запуске окно не отбирает фокус: приложение стартует само,
    // и перехватывать клавиатуру у того, кто уже печатает, нельзя
    func showOnboarding(activate: Bool) {
        if let w = onboardingWindow {
            if activate {
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                w.orderFrontRegardless()
            }
            return
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let title = NSTextField(labelWithString: "LayoutGlow \(version)")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Три шага, и всё заработает")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let steps = NSStackView(views: [
            stepCard(number: 1, title: "Мониторинг ввода",
                     detail: "Чтобы ловить нажатия клавиш и тап Fn", button: "Открыть настройки",
                     action: #selector(openInputMonitoring), tag: 1),
            stepCard(number: 2, title: "Универсальный доступ",
                     detail: "Чтобы исправлять текст и находить курсор", button: "Открыть настройки",
                     action: #selector(openAccessibility), tag: 2),
            stepCard(number: 3, title: "Клавиша Globe",
                     detail: "«Press Globe key to» поставить в «Do Nothing», иначе тап Fn останется медленным",
                     button: "Открыть клавиатуру", action: #selector(openKeyboardSettings), tag: 3),
        ])
        steps.orientation = .vertical
        steps.spacing = 12
        steps.alignment = .leading
        steps.distribution = .fill

        let repairButton = NSButton(title: "Выдать разрешения заново", target: self,
                                    action: #selector(repairPermissions))
        repairButton.bezelStyle = .rounded
        repairButton.controlSize = .large
        repairButton.toolTip = "Если галочка стоит, а доступа нет — обычно после обновления"

        let shortcutsButton = NSButton(title: "Справка по сочетаниям", target: self, action: #selector(showShortcuts))
        shortcutsButton.bezelStyle = .rounded
        shortcutsButton.controlSize = .large
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let done = NSButton(title: "Готово", target: self, action: #selector(finishOnboarding))
        done.bezelStyle = .rounded
        done.controlSize = .large
        done.bezelColor = .controlAccentColor

        let buttons = NSStackView(views: [shortcutsButton, repairButton, spacer, done])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let root = NSStackView(views: [title, subtitle, steps, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Настройка LayoutGlow"
        w.isReleasedWhenClosed = false
        w.level = .floating
        let container = NSView()
        w.contentView = container
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            steps.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
        ])
        w.center()

        if activate {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            w.orderFrontRegardless()
        }
        onboardingWindow = w
        refreshOnboardingStatus()
        onboardingTimer?.invalidate()
        onboardingTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshOnboardingStatus()
        }
    }

    // Карточка шага: номер, заголовок, статус, пояснение и кнопка
    func stepCard(number: Int, title: String, detail: String,
                  button: String, action: Selector, tag: Int) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor

        let badge = NSTextField(labelWithString: "\(number)")
        badge.font = .systemFont(ofSize: 13, weight: .bold)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 11
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 22).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)

        let status = NSTextField(labelWithString: "проверяю…")
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.tag = 100 + tag

        let head = NSStackView(views: [badge, name, status])
        head.orientation = .horizontal
        head.spacing = 8
        head.alignment = .centerY

        let text = NSTextField(wrappingLabelWithString: detail)
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor

        let act = NSButton(title: button, target: self, action: action)
        act.bezelStyle = .rounded

        let stack = NSStackView(views: [head, text, act])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    func refreshOnboardingStatus() {
        guard let root = onboardingWindow?.contentView else { return }
        let fnUsage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString,
                                                "com.apple.HIToolbox" as CFString) as? Int ?? -1
        let states: [Int: Bool] = [101: eventTap != nil, 102: AXIsProcessTrusted(), 103: fnUsage == 0]
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, let done = states[field.tag] {
                field.stringValue = done ? "готово" : "нужно включить"
                field.textColor = done ? .systemGreen : .systemOrange
            }
            view.subviews.forEach(walk)
        }
        walk(root)
    }

    @objc func finishOnboarding() {
        Settings.shared.onboarded = true
        onboardingTimer?.invalidate()
        onboardingTimer = nil
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // После смены подписи (например, когда сборка пересоздана с новым
    // сертификатом) старая запись в списке разрешений уже не относится
    // к приложению: галочка стоит, доступа нет. Лечится сбросом записи
    @objc func repairPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = "Выдать разрешения заново?"
        dialog.informativeText = "Записи в списках «Универсальный доступ» и «Мониторинг ввода» будут сброшены, "
            + "приложение перезапустится и запросит доступ заново. Это помогает, когда галочка стоит, "
            + "а доступа нет."
        dialog.addButton(withTitle: "Сбросить и перезапустить")
        dialog.addButton(withTitle: "Отмена")
        guard dialog.runModal() == .alertFirstButtonReturn else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "ru.devkz.layoutglow"
        for service in ["Accessibility", "ListenEvent"] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", service, bundleID]
            try? task.run()
            task.waitUntilExit()
        }
        log("разрешения сброшены по просьбе пользователя, перезапуск")
        relaunch()
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "sleep 1; open -a \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard")!)
    }

    // MARK: Синтетический ввод

    func postKey(_ keycode: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMagic)
            e.post(tap: .cgSessionEventTap)
            usleep(2500)
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

    // Заменяет последние `count` символов текстом. Раньше здесь были backspace
    // и посимвольная перепечатка — события уходили быстрее, чем приложение
    // успевало их обработать, отсюда «ККОШКА» вместо «КОШКА». Выделение
    // стрелками плюс одна вставка атомарны и от скорости не зависят.
    func replaceLast(_ count: Int, with text: String, switchTo target: TISInputSource?,
                     guardTick: Int? = nil, source: String = "авто") {
        guard ensureAccessibility() else { return }
        guard !replaceInProgress else {
            log("замена: предыдущая ещё идёт, пропуск")
            return
        }
        replaceInProgress = true
        // Страховка: если приложение не ответит, флаг не должен залипнуть навсегда
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.replaceInProgress else { return }
            self.replaceInProgress = false
            self.log("замена: сброс по таймауту")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: watchdog)

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        DispatchQueue.global(qos: .userInteractive).async {
            func finish(_ note: String?) {
                DispatchQueue.main.async {
                    watchdog.cancel()
                    if let note { self.log(note) }
                    self.replaceInProgress = false
                }
            }
            // Забираем то, что человек успел набрать после границы слова:
            // эти буквы уже в тексте, и наши backspace их бы съели
            // Хвост читаем в той раскладке, в которую переходим: человек
            // уже печатал нужный язык, просто раскладка не успела смениться
            func takeTyped() -> [Stroke] {
                DispatchQueue.main.sync {
                    let typed = self.typedAfterBoundary
                    self.typedAfterBoundary.removeAll()
                    return typed
                }
            }
            let tailLayout = DispatchQueue.main.sync { target ?? currentSource() }
            // По SSH эхо приходит с задержкой, поэтому в терминалах медленнее
            let slow = DispatchQueue.main.sync { self.isTerminalLike(self.frontApp) }
            func erase(_ amount: Int) {
                guard amount > 0 else { return }
                for _ in 0..<amount {
                    self.postKey(51)
                    if slow { usleep(12000) }
                }
                usleep(slow ? 160000 : 50000)
            }

            var tail = takeTyped()
            guard tail.count < 16 else { return finish("замена отменена: печать не останавливается") }
            erase(count + tail.count)

            // Пока стирали, могли добавиться ещё буквы — стираем и их,
            // но вернём в конце вместе с исправленным словом
            for _ in 0..<2 {
                let extra = takeTyped()
                guard !extra.isEmpty else { break }
                tail += extra
                erase(extra.count)
            }

            // Разбор раскладки — только с главного потока: системный вызов
            // проверяет очередь и роняет процесс
            let tailText: String = DispatchQueue.main.sync {
                let result = tailLayout.map { translate(tail, via: $0) } ?? ""
                self.writeClipboard(text + result)
                return result
            }
            usleep(slow ? 90000 : 30000)
            self.postKey(9, flags: .maskCommand)  // Cmd+V
            usleep(slow ? 400000 : 260000)
            DispatchQueue.main.async {
                watchdog.cancel()
                if let target { TISSelectInputSource(target) }
                self.restoreClipboard(saved)
                self.replaceInProgress = false
                self.typedAfterBoundary.removeAll()
                self.verifyReplacement(expected: text + tailText, source: source, tick: self.inputTick)
            }
        }
    }

    // Что стоит перед курсором: по этому проверяем, что замена дошла
    func textBeforeCaret(_ length: Int) -> String? {
        guard length > 0, let element = focusedElement() else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var caret = CFRange()
        AXValueGetValue(rv as! AXValue, .cfRange, &caret)
        let available = min(length, caret.location)
        guard available > 0 else { return nil }
        var range = CFRange(location: caret.location - available, length: available)
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var textRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, value, &textRef) == .success,
              let text = textRef as? String else { return nil }
        return text
    }

    // Приложение могло проглотить наши нажатия и промолчать — раньше такие
    // сбои были невидимы и выглядели как «иногда не срабатывает»
    func verifyReplacement(expected: String, source: String = "авто", tick: Int = 0) {
        guard !expected.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Если человек уже набрал что-то после замены, текст перед
            // курсором принадлежит ему, и сверять его бессмысленно:
            // раньше это давало ложные «НЕ УДАЛОСЬ»
            guard self.inputTick == tick else {
                self.recordCorrection("[\(source)] «\(expected.trimmingCharacters(in: .whitespaces))» — набор продолжился, не проверяю")
                return
            }
            guard let actual = self.textBeforeCaret(expected.count) else {
                self.recordCorrection("[\(source)] «\(expected.trimmingCharacters(in: .whitespaces))» — проверить не удалось")
                return
            }
            if actual == expected {
                self.recordCorrection("[\(source)] «\(expected.trimmingCharacters(in: .whitespaces))» — заменено")
            } else {
                self.log("замена не подтвердилась: ожидалось «\(expected)», в тексте «\(actual)»")
                self.recordCorrection("[\(source)] «\(expected.trimmingCharacters(in: .whitespaces))» — НЕ УДАЛОСЬ, в тексте «\(actual)»")
                self.showPill(text: "не удалось", color: .systemRed)
            }
        }
    }

    // Помечаем содержимое временным: менеджеры буфера обмена (Raycast,
    // Alfred, Paste) такие записи в историю не заносят
    func writeClipboard(_ text: String) {
        let pb = NSPasteboard.general
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        pb.clearContents()
        pb.declareTypes([.string, transient], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: transient)
    }

    func restoreClipboard(_ saved: String?) {
        guard let saved else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(saved, forType: .string)
    }

    func replaceWithText(backspaces: Int, text: String, source: String = "вставка") {
        // Здесь набранное слово заменяется целиком, поэтому «хвост»
        // компенсировать нечего: он и есть это слово
        typedAfterBoundary.removeAll()
        replaceLast(backspaces, with: text, switchTo: nil, source: source)
    }

    // MARK: Горячие клавиши слотов (Cmd+Option+1...9)

    // Файл сочетаний мог быть создан прежней версией: дописываем
    // действия, которых в нём ещё нет, не трогая уже настроенные
    // Терминал, который пользователь разрешил сам, работает полностью:
    // предохранители (короткие слова не трогаем, нажатия медленнее)
    // делают это безопасным. Осторожный режим — только для незнакомых
    func migrateTerminalModes() {
        guard !UserDefaults.standard.bool(forKey: "terminalModesRestored") else { return }
        UserDefaults.standard.set(true, forKey: "terminalModesRestored")
        var modes = Settings.shared.appModes
        var restored: [String] = []
        for bid in Settings.shared.allowedApps
        where isTerminalLike(bundleID: bid) && modes[bid] == AppMode.manual.rawValue {
            modes.removeValue(forKey: bid)
            restored.append(appName(for: bid))
        }
        guard !restored.isEmpty else { return }
        Settings.shared.appModes = modes
        log("терминалам возвращён полный режим: \(restored.joined(separator: ", "))")
    }

    func ensureDefaultHotkeys() {
        let defaults = SnippetFile.parse(defaultHotkeys.joined(separator: "\n"))
        let missing = defaults.filter { hotkeysFile.value(for: $0.key) == nil }
        guard !missing.isEmpty else { return }
        var pairs = hotkeysFile.items.map { ($0.key, $0.value) }
        pairs.append(contentsOf: missing.map { ($0.key, $0.value) })
        hotkeysFile.replaceAll(pairs.sorted { $0.0 < $1.0 })
        log("в сочетания добавлены новые действия: \(missing.keys.sorted().joined(separator: ", "))")
    }

    func registerSlotHotkeys() {
        for ref in hotKeyRefs { if let ref { UnregisterEventHotKey(ref) } }
        hotKeyRefs.removeAll()

        if !hotkeyHandlerInstalled {
            hotkeyHandlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    switch hkID.id {
                    case 100: me.convertLine()
                    case 101: me.convertParagraph()
                    case 102: me.expandSnippet()
                    case 103: me.clipboard?.togglePanel()
                    case 200...209: me.insertPreset(Int(hkID.id) - 199)
                    default: me.insertSlot(Int(hkID.id))
                    }
                }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        }

        // Действия и их номера; клавиши берём из hotkeys.txt
        var actions: [(String, UInt32)] = [("строка", 100), ("абзац", 101), ("ключ", 102), ("буфер", 103)]
        for n in 1...9 { actions.append(("слот-\(n)", UInt32(n))) }
        for n in 1...10 { actions.append(("пресет-\(n)", UInt32(199 + n))) }

        var failed: [String] = []
        for (name, id) in actions {
            guard let text = hotkeysFile.value(for: name) else { continue }
            guard let hotkey = parseHotkey(text) else {
                failed.append("\(name): не разобрать «\(text)»")
                continue
            }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(hotkey.keycode, hotkey.modifiers,
                                             EventHotKeyID(signature: OSType(0x4C474C4F), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr { hotKeyRefs.append(ref) } else { failed.append("\(name): занято (\(text))") }
        }
        if !failed.isEmpty { log("сочетания: \(failed.joined(separator: "; "))") }
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

    // После обновления прогоняем дымовые тесты и, если новая версия
    // сломана, сами возвращаемся на предыдущую. Ждём простоя: тест
    // печатает в собственное окно и мешать работе не должен
    func armPostUpdateCheck() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard UserDefaults.standard.string(forKey: "lastVerifiedVersion") != current else { return }
        verifyArmed = true
        log("версия \(current) ещё не проверена, жду простоя")
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
            guard let self, self.verifyArmed else { timer.invalidate(); return }
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                               eventType: .init(rawValue: ~0)!)
            guard idle > 45, !self.replaceInProgress else { return }
            self.verifyArmed = false
            timer.invalidate()
            self.runSelfCheck()
        }
    }

    func runSelfCheck() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        log("самопроверка версии \(current)")
        pausedForSmoke = true
        let report = runtimeDirectory().appendingPathComponent("smoke.log")
        try? FileManager.default.removeItem(at: report)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", "-W", "-a", "/Applications/LayoutGlow.app", "--args", "--smoke-test"]
        task.terminationHandler = { [weak self] process in
            guard let self else { return }
            let text = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
            let failed = process.terminationStatus != 0 || text.contains("Провалено")
            DispatchQueue.main.async {
                self.pausedForSmoke = false
                if failed {
                    self.log("самопроверка провалена, откатываюсь")
                    self.recordCorrection("самопроверка версии \(current) провалена — откат")
                    self.notify("LayoutGlow: версия \(current) не прошла самопроверку",
                                "Возвращаюсь на предыдущую версию.")
                    self.rollbackAutomatically()
                } else {
                    UserDefaults.standard.set(current, forKey: "lastVerifiedVersion")
                    self.log("самопроверка версии \(current) пройдена")
                }
            }
        }
        do { try task.run() } catch {
            pausedForSmoke = false
            log("самопроверку запустить не удалось: \(error.localizedDescription)")
        }
    }

    func notify(_ title: String, _ text: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = text
        NSUserNotificationCenter.default.deliver(notification)
    }

    func rollbackAutomatically() {
        previousRelease { [weak self] release in
            guard let self, let release else { return }
            self.log("автооткат на версию \(release.0)")
            self.downloadAndInstall(release.1)
        }
    }

    // Ближайший релиз старше установленного, у которого есть готовая сборка
    func previousRelease(_ completion: @escaping ((String, String)?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/kzhebenev/layout-glow/releases?per_page=10") else {
            completion(nil); return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            guard let data,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let found = list.compactMap { release -> (String, String)? in
                guard let tag = release["tag_name"] as? String else { return nil }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                guard version.compare(current, options: .numeric) == .orderedAscending else { return nil }
                let assets = release["assets"] as? [[String: Any]] ?? []
                guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                      let link = dmg["browser_download_url"] as? String else { return nil }
                return (version, link)
            }.first
            DispatchQueue.main.async { completion(found) }
        }.resume()
    }

    // Откат на предыдущий релиз: если обновление оказалось хуже,
    // ждать исправления не нужно
    @objc func rollbackToPrevious() {
        previousRelease { [weak self] release in
            guard let self else { return }
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            guard let release else {
                self.alert("Откатываться некуда", "Более ранних версий с готовой сборкой не нашлось.")
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            let dialog = NSAlert()
            dialog.messageText = "Вернуться на версию \(release.0)?"
            dialog.informativeText = "Установлена \(current). Приложение перезапустится."
            dialog.addButton(withTitle: "Вернуться")
            dialog.addButton(withTitle: "Отмена")
            if dialog.runModal() == .alertFirstButtonReturn {
                self.log("откат на версию \(release.0)")
                self.downloadAndInstall(release.1)
            }
        }
    }

    @objc func runSelfCheckNow() { runSelfCheck() }

    // Отрисовка собственных окон в файл: позволяет посмотреть на интерфейс
    // со стороны, когда снимок экрана недоступен
    @objc func snapshotWindows() {
        for window in NSApp.windows where window.isVisible {
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let name = window.title.isEmpty ? "окно" : window.title.replacingOccurrences(of: " ", with: "-")
            try? data.write(to: runtimeDirectory().appendingPathComponent("snapshot-\(name).png"))
        }
        preferences?.snapshotAllTabs()
        log("снимки окон сохранены")
    }

    @objc func showPreferences() {
        if preferences == nil { preferences = PreferencesWindow(delegate: self) }
        preferences?.show()
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

let smokeMode = CommandLine.arguments.contains("--smoke-test")
let app = NSApplication.shared
app.setActivationPolicy(smokeMode ? .regular : .accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
