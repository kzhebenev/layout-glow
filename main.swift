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

let glowHeight: CGFloat = 48     // высота полосы свечения у нижнего края
let flashAlpha: CGFloat = 0.95   // вспышка в момент переключения
let pillLifetime = 1.0           // сколько секунд висит плашка

// MARK: - Поведение

let maxFnTap = 0.6               // дольше держал Fn — не тап
let doubleShiftWindow = 0.5      // окно двойного тапа Shift
let maxWordLen = 32

// Дефис и апостроф внутри слова допустимы: «дабл-шифт» разбирается по частям
let wordSeparators: Set<Character> = ["-", "'", "\u{2019}"]

// Спеллчекер считает валидной любую одиночную букву, поэтому
// однобуквенные слова разрешены только по списку
let singleLetterWords: [String: Set<String>] = [
    "ru": ["я", "в", "и", "к", "с", "у", "а", "о"],
    "en": ["a", "i"],
]
let syntheticMagic: Int64 = 0x4C474C4F  // метка наших синтетических событий

// Приложения, где автоисправление выключено по умолчанию.
// Меняется на лету из меню («Автоисправление в …»), Termius сюда не входит.
let defaultExcludedApps = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
    "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "com.github.wez.wezterm",
]

struct Stroke {
    let keycode: CGKeyCode
    let shift: Bool
    let caps: Bool
}

// MARK: - Настройки (живут в UserDefaults, правятся из меню)

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "fnSwitch": true,
            "autoCorrect": true,
            "manualConvert": true,
            "excludedApps": defaultExcludedApps,
            "exceptions": [String](),
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
    var excludedApps: Set<String> {
        get { Set(d.stringArray(forKey: "excludedApps") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "excludedApps") }
    }
    var exceptions: Set<String> {
        get { Set(d.stringArray(forKey: "exceptions") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "exceptions") }
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
    func addException(_ word: String) {
        var s = exceptions
        s.insert(word.lowercased())
        exceptions = s
    }
}

// MARK: - Раскладки

func currentLayoutFullID() -> String {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func currentLayout() -> String {
    let id = currentLayoutFullID()
    return id.components(separatedBy: ".").last ?? id
}

func sourceID(_ s: TISInputSource) -> String {
    guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

func sourceName(_ s: TISInputSource) -> String {
    guard let p = TISGetInputSourceProperty(s, kTISPropertyLocalizedName) else { return "" }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

func sourceLang(_ s: TISInputSource) -> String {
    if let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceLanguages),
       let langs = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String],
       let first = langs.first { return first }
    return "en"
}

func enabledLayouts() -> [TISInputSource] {
    let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                  kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
    guard let cfList = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return [] }
    return cfList as NSArray as! [TISInputSource]
}

func currentSource() -> TISInputSource? {
    TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
}

func otherLayout() -> TISInputSource? {
    let cur = currentLayoutFullID()
    return enabledLayouts().first(where: { sourceID($0) != cur })
}

// Что дадут эти клавиши в указанной раскладке
func translate(_ strokes: [Stroke], via source: TISInputSource) -> String {
    guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "" }
    let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
    return data.withUnsafeBytes { buf -> String in
        guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
        var result = ""
        var deadKeys: UInt32 = 0
        for s in strokes {
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            UCKeyTranslate(layout, s.keycode, UInt16(kUCKeyActionDown),
                           s.shift ? (UInt32(shiftKey) >> 8) & 0xFF : 0,
                           UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                           &deadKeys, 4, &length, &chars)
            var piece = String(utf16CodeUnits: chars, count: length)
            if s.caps && !s.shift { piece = piece.uppercased() }
            result += piece
        }
        return result
    }
}

// Посимвольная карта одной раскладки в другую (для конвертации выделенного текста)
func charMap(from a: TISInputSource, to b: TISInputSource) -> [Character: Character] {
    var map = [Character: Character]()
    for code in 0...50 {
        for shift in [false, true] {
            let s = [Stroke(keycode: CGKeyCode(code), shift: shift, caps: false)]
            let from = translate(s, via: a)
            let to = translate(s, via: b)
            if let cf = from.first, let ct = to.first,
               from.count == 1, to.count == 1, cf != ct {
                map[cf] = ct
            }
        }
    }
    return map
}

func isValidWord(_ word: String, lang: String) -> Bool {
    guard !word.isEmpty else { return false }
    let r = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: lang,
                                                wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
    return r.location == NSNotFound
}

// Буквы, между которыми допустимы дефис и апостроф
func isWordLike(_ s: String) -> Bool {
    guard let first = s.first, let last = s.last, first.isLetter, last.isLetter,
          s.allSatisfy({ $0.isLetter || wordSeparators.contains($0) }) else { return false }
    return true
}

func wordParts(_ s: String) -> [String] {
    s.split(whereSeparator: { wordSeparators.contains($0) }).map(String.init)
}

// Осмысленно ли это на данном языке: каждая часть — словарное слово,
// а однобуквенные — только из списка
func meaningful(_ s: String, lang: String) -> Bool {
    let base = String(lang.prefix(2)).lowercased()
    let parts = wordParts(s)
    guard !parts.isEmpty else { return false }
    return parts.allSatisfy { part in
        if part.count == 1 {
            return singleLetterWords[base]?.contains(part.lowercased()) ?? false
        }
        return isValidWord(part, lang: lang)
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
    var lastLayout = ""
    var statusItem: NSStatusItem?

    var eventTap: CFMachPort?
    var fnDown = false
    var fnUsedAsModifier = false
    var fnDownAt: TimeInterval = 0
    var accessRequested = false

    var wordBuffer: [Stroke] = []
    var lastWord: [Stroke]?
    var lastWordTrailing = 0
    var shiftDown = false
    var shiftUsedAsModifier = false
    var lastShiftTapAt: TimeInterval = 0
    var replaceInProgress = false
    var lastAutoTyped: String?          // что автоисправление заменило (для самообучения)
    var frontApp: NSRunningApplication? // последнее не наше активное приложение

    // Диагностика: пишется в ~/Library/Application Support/LayoutGlow/status.log
    var keysSeen = 0
    var shiftTaps = 0
    var doubleShifts = 0
    var events: [String] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        if Bundle.main.bundlePath.hasSuffix(".app"),
           SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        buildGlowWindows()
        buildStatusItem()
        apply(layout: currentLayout(), animated: false)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(layoutChanged),
            name: NSNotification.Name("AppleSelectedInputSourcesChangedNotification"),
            object: nil, suspensionBehavior: .deliverImmediately)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        frontApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier != Bundle.main.bundleIdentifier { self?.frontApp = app }
            self?.wordBuffer.removeAll()
            self?.lastWord = nil
        }

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = currentLayout()
            if now != self.lastLayout { self.apply(layout: now, animated: true) }
        }

        startTap()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.4)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.writeStatus() }
        writeStatus()

        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
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
    }

    func apply(layout: String, animated: Bool) {
        lastLayout = layout
        let style = styles[layout] ?? fallbackStyle
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
        if animated { showPill(text: style.label, color: style.color) }
    }

    func showPill(text: String, color: NSColor) {
        pillTimer?.invalidate()
        pillWindow?.orderOut(nil)

        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: max(92, CGFloat(text.count) * 18 + 40), height: 44)
        let f = screen.frame
        let rect = NSRect(x: f.midX - size.width / 2, y: f.minY + 96,
                          width: size.width, height: size.height)

        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

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

    // MARK: Диагностика

    func log(_ line: String) {
        events.append(line)
        if events.count > 40 { events.removeFirst(events.count - 40) }
        writeStatus()
    }

    func writeStatus() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LayoutGlow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fnUsage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString,
                                                "com.apple.HIToolbox" as CFString) as? Int ?? -1
        var text = """
        перехват клавиатуры: \(eventTap != nil ? "работает" : "НЕТ (нужен Мониторинг ввода)")
        универсальный доступ: \(AXIsProcessTrusted() ? "выдан" : "НЕ ВЫДАН")
        нажатий получено: \(keysSeen)
        тапов Shift: \(shiftTaps), из них двойных: \(doubleShifts)
        в буфере слова: \(wordBuffer.count) симв.
        AppleFnUsageType: \(fnUsage) (0 = Do Nothing, тап Fn наш)
        раскладка: \(lastLayout)
        активное приложение: \(frontApp?.bundleIdentifier ?? "—")
        автоисправление: \(Settings.shared.autoCorrect), двойной Shift: \(Settings.shared.manualConvert)

        события:
        """
        text += "\n" + events.joined(separator: "\n") + "\n"
        try? text.write(to: dir.appendingPathComponent("status.log"), atomically: true, encoding: .utf8)
    }

    // MARK: Меню-бар

    // Имена приложений, которые могут быть не установлены на этом маке
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

        func toggle(_ title: String, _ on: Bool, _ selector: Selector) {
            let i = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            i.state = on ? .on : .off
            i.target = self
            menu.addItem(i)
        }
        toggle("Быстрое переключение по Fn", s.fnSwitch, #selector(toggleFn))
        toggle("Автоисправление раскладки", s.autoCorrect, #selector(toggleAuto))
        toggle("Конвертация по двойному Shift", s.manualConvert, #selector(toggleManual))

        menu.addItem(.separator())
        if let app = frontApp, let bid = app.bundleIdentifier {
            let name = app.localizedName ?? appName(for: bid)
            toggle("Автоисправление в «\(name)»", !s.isExcluded(bid), #selector(toggleFrontApp))
        }
        // Показываем только то, что реально установлено: список по умолчанию
        // содержит терминалы, которых на этом маке может не быть
        let excluded = s.excludedApps.filter { isInstalled($0) }.sorted { appName(for: $0) < appName(for: $1) }
        if !excluded.isEmpty {
            let sub = NSMenu()
            for bid in excluded {
                let i = NSMenuItem(title: appName(for: bid), action: #selector(removeExcludedApp(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = bid
                i.toolTip = "\(bid) — нажмите, чтобы включить автоисправление здесь"
                sub.addItem(i)
            }
            let head = NSMenuItem(title: "Выключено в приложениях (\(excluded.count))", action: nil, keyEquivalent: "")
            menu.addItem(head)
            menu.setSubmenu(sub, for: head)
        }

        menu.addItem(.separator())
        let words = s.exceptions.sorted()
        let exHead = NSMenuItem(title: "Слова-исключения (\(words.count))", action: nil, keyEquivalent: "")
        menu.addItem(exHead)
        if !words.isEmpty {
            let sub = NSMenu()
            for w in words {
                let i = NSMenuItem(title: w, action: #selector(removeException(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = w
                sub.addItem(i)
            }
            sub.addItem(.separator())
            let clear = NSMenuItem(title: "Очистить список", action: #selector(clearExceptions), keyEquivalent: "")
            clear.target = self
            sub.addItem(clear)
            menu.setSubmenu(sub, for: exHead)
        }

        menu.addItem(.separator())
        let inputOK = eventTap != nil
        let axOK = AXIsProcessTrusted()
        let i1 = NSMenuItem(title: "Мониторинг ввода: \(inputOK ? "выдан" : "НЕ ВЫДАН")",
                            action: #selector(openInputMonitoring), keyEquivalent: "")
        i1.target = self
        menu.addItem(i1)
        let i2 = NSMenuItem(title: "Универсальный доступ: \(axOK ? "выдан" : "НЕ ВЫДАН")",
                            action: #selector(openAccessibility), keyEquivalent: "")
        i2.target = self
        menu.addItem(i2)

        menu.addItem(.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        menu.addItem(withTitle: "LayoutGlow \(version)", action: nil, keyEquivalent: "")
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func toggleFn() { Settings.shared.fnSwitch.toggle() }
    @objc func toggleAuto() { Settings.shared.autoCorrect.toggle() }
    @objc func toggleManual() { Settings.shared.manualConvert.toggle() }
    @objc func toggleFrontApp() {
        guard let bid = frontApp?.bundleIdentifier else { return }
        Settings.shared.setExcluded(bid, !Settings.shared.isExcluded(bid))
    }
    @objc func removeExcludedApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        Settings.shared.setExcluded(bid, false)
    }
    @objc func removeException(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? String else { return }
        var s = Settings.shared.exceptions
        s.remove(w)
        Settings.shared.exceptions = s
    }
    @objc func clearExceptions() { Settings.shared.exceptions = [] }
    @objc func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

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
                let now = ProcessInfo.processInfo.systemUptime
                if Settings.shared.manualConvert && !shiftUsedAsModifier {
                    shiftTaps += 1
                    if now - lastShiftTapAt < doubleShiftWindow {
                        lastShiftTapAt = 0
                        doubleShifts += 1
                        DispatchQueue.main.async { self.manualConvert() }
                    } else {
                        lastShiftTapAt = now
                    }
                } else {
                    lastShiftTapAt = 0
                }
            }
        case .flagsChanged:
            if fnDown { fnUsedAsModifier = true }
            if shiftDown { shiftUsedAsModifier = true }
        case .keyDown:
            if fnDown { fnUsedAsModifier = true }
            if shiftDown { shiftUsedAsModifier = true }
            trackKey(event: event, keycode: keycode)
        default:
            break
        }
    }

    func toggleLayout() {
        // Пока системный «Press Globe key to» не в «Do Nothing», не дублируем систему
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
                wordBuffer.append(stroke)
                keysSeen += 1
            if wordBuffer.count > maxWordLen { wordBuffer.removeAll(); lastWord = nil }
            }
        }
    }

    func autoCorrect(_ word: [Stroke]) {
        guard !word.isEmpty,
              let cur = currentSource(), let other = otherLayout() else { return }
        if Settings.shared.isExcluded(frontApp?.bundleIdentifier) { return }

        let typed = translate(word, via: cur)
        defer { writeStatus() }
        let capsOn = word.contains(where: { $0.caps })
        // Аббревиатура (HD, СКЗИ): всё заглавными и Caps Lock не был включён
        if !capsOn, typed.rangeOfCharacter(from: .letters) != nil, typed == typed.uppercased() { return }
        if Settings.shared.exceptions.contains(typed.lowercased()) { return }

        let converted = translate(word, via: other)
        let srcLang = sourceLang(cur), dstLang = sourceLang(other)
        guard isWordLike(converted) else {
            log("пропуск «\(typed)»: не слово целиком")
            return
        }
        guard !meaningful(typed, lang: srcLang) else {
            log("пропуск «\(typed)»: валидно в \(srcLang)")
            return
        }
        guard meaningful(converted, lang: dstLang) else {
            log("пропуск «\(typed)»: «\(converted)» невалидно в \(dstLang)")
            return
        }

        log("исправлено «\(typed)» -> «\(converted)»")
        lastAutoTyped = typed
        performReplace(strokes: word, trailingSpaces: 1, to: other)
        lastWord = word
        lastWordTrailing = 1
    }

    // MARK: Ручная конвертация (двойной Shift)

    func manualConvert() {
        // Сначала пробуем выделенный текст — конвертируем его целиком
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
        log("двойной Shift: «\(currentSource().map { translate(strokes, via: $0) } ?? "")» -> «\(translate(strokes, via: other))»")

        // Откат автоисправления = слово уходит в исключения (самообучение)
        if let typed = lastAutoTyped, let cur = currentSource(),
           translate(strokes, via: other) == typed {
            Settings.shared.addException(typed)
            lastAutoTyped = nil
            _ = cur
            showPill(text: "искл.", color: .systemGray)
        }

        performReplace(strokes: strokes, trailingSpaces: trailing, to: other)
        wordBuffer.removeAll()
        lastWord = strokes
        lastWordTrailing = trailing
    }

    // Конвертация выделенного текста через Универсальный доступ, с запасным путём через буфер обмена
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

        // Запасной путь: вставка через буфер обмена
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

    // Определяем направление по содержимому и конвертируем текст посимвольно
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
        let converted = String(text.map { map[$0] ?? $0 })
        return (converted, target)
    }

    // MARK: Перепечатка

    func postKey(_ keycode: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMagic)
            e.post(tap: .cgSessionEventTap)
            usleep(1200)
        }
    }

    func performReplace(strokes: [Stroke], trailingSpaces: Int, to target: TISInputSource) {
        guard !replaceInProgress else { return }
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            return
        }
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
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
