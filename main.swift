import Cocoa
import Carbon
import ServiceManagement
import IOKit.hid

// Настройки: цвет и яркость свечения для каждой раскладки.
// Ключ — суффикс InputSourceID (com.apple.keylayout.<...>).
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
let pillLifetime = 1.0           // сколько секунд висит плашка RU/EN

// Быстрое переключение по Fn (нужно разрешение Input Monitoring,
// а системную «Press 🌐 key to» поставить в «Do Nothing»)
let fnSwitchEnabled = true
let maxFnTap = 0.6               // дольше держал — не считаем тапом

// Режим Punto/Caramba: автоисправление слова, набранного не в той раскладке,
// и ручная конвертация последнего слова по двойному тапу Shift.
// Дополнительно нужно разрешение Accessibility (чтобы перепечатать слово).
let autoCorrectEnabled = true
let manualConvertEnabled = true
let doubleShiftWindow = 0.35     // окно двойного тапа Shift, сек
let minAutoWordLen = 3           // короче — автоисправление не трогает
let maxWordLen = 24              // длиннее — не буферизуем
// Здесь автоисправление молчит (двойной Shift работает везде)
let excludedBundleIDs: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
    "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "com.github.wez.wezterm",
]

struct Stroke { let keycode: CGKeyCode; let shift: Bool }
let syntheticMagic: Int64 = 0x4C474C4F  // метка наших синтетических событий

func currentLayoutFullID() -> String {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func currentLayout() -> String {
    let id = currentLayoutFullID()
    return id.components(separatedBy: ".").last ?? id
}

final class GlowView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let gradient = NSGradient(colors: [color, color.withAlphaComponent(0)])
        gradient?.draw(in: bounds, angle: 90)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var glowWindows: [NSWindow] = []
    var pillWindow: NSWindow?
    var pillTimer: Timer?
    var lastLayout = ""

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

    func applicationDidFinishLaunching(_ note: Notification) {
        // Автозапуск при входе: регистрируем себя как Login Item (только из .app-бандла)
        if Bundle.main.bundlePath.hasSuffix(".app"),
           SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        buildGlowWindows()
        apply(layout: currentLayout(), animated: false)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(layoutChanged),
            name: NSNotification.Name("AppleSelectedInputSourcesChangedNotification"),
            object: nil, suspensionBehavior: .deliverImmediately)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Подстраховка: уведомление иногда не приходит из некоторых приложений
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = currentLayout()
            if now != self.lastLayout { self.apply(layout: now, animated: true) }
        }

        if fnSwitchEnabled || autoCorrectEnabled || manualConvertEnabled { startFnTap() }

        // Для перепечатки слова нужен Accessibility — просим сразу, если не выдан
        if autoCorrectEnabled || manualConvertEnabled {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
    }

    // MARK: Быстрое переключение по Fn

    func startFnTap() {
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
            // Нет разрешения Input Monitoring: просим один раз и ждём, пока выдадут
            if !accessRequested {
                accessRequested = true
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startFnTap() }
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
        case .flagsChanged where keycode == 63:  // сама клавиша Fn/Globe
            if shiftDown { shiftUsedAsModifier = true }
            let pressed = event.flags.contains(.maskSecondaryFn)
            if pressed && !fnDown {
                fnDown = true
                fnUsedAsModifier = false
                fnDownAt = ProcessInfo.processInfo.systemUptime
            } else if !pressed && fnDown {
                fnDown = false
                let held = ProcessInfo.processInfo.systemUptime - fnDownAt
                if !fnUsedAsModifier && held < maxFnTap {
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
                if manualConvertEnabled && !shiftUsedAsModifier {
                    if now - lastShiftTapAt < doubleShiftWindow {
                        lastShiftTapAt = 0
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

    // MARK: Режим Punto: буфер слова, автоисправление, ручная конвертация

    func trackKey(event: CGEvent, keycode: Int64) {
        guard autoCorrectEnabled || manualConvertEnabled else { return }
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
                if autoCorrectEnabled { DispatchQueue.main.async { self.autoCorrect(word) } }
            } else if lastWord != nil {
                lastWordTrailing = min(lastWordTrailing + 1, 4)
            }
        case 51:  // backspace
            if wordBuffer.isEmpty { lastWord = nil } else { wordBuffer.removeLast() }
        case 36, 76, 48, 53, 117, 115, 116, 119, 121, 123, 124, 125, 126:
            // enter/tab/esc/навигация: конвертировать сквозь них небезопасно
            wordBuffer.removeAll(); lastWord = nil
        default:
            let stroke = Stroke(keycode: CGKeyCode(keycode), shift: flags.contains(.maskShift))
            // Запоминаем только клавиши, дающие видимый символ
            if let cur = currentSource(), !translate([stroke], via: cur).isEmpty {
                wordBuffer.append(stroke)
                if wordBuffer.count > maxWordLen { wordBuffer.removeAll(); lastWord = nil }
            }
        }
    }

    func autoCorrect(_ word: [Stroke]) {
        guard word.count >= minAutoWordLen,
              let cur = currentSource(), let other = otherLayout() else { return }
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           excludedBundleIDs.contains(bid) { return }
        let typed = translate(word, via: cur)
        let converted = translate(word, via: other)
        guard converted.count >= minAutoWordLen,
              converted.allSatisfy({ $0.isLetter }),
              !isValidWord(typed, lang: lang(of: cur)),
              isValidWord(converted, lang: lang(of: other)) else { return }
        performReplace(strokes: word, trailingSpaces: 1, to: other)
        lastWord = word
        lastWordTrailing = 1
    }

    func manualConvert() {
        guard let other = otherLayout() else { return }
        let strokes: [Stroke]
        let trailing: Int
        if !wordBuffer.isEmpty {
            strokes = wordBuffer; trailing = 0
        } else if let lw = lastWord {
            strokes = lw; trailing = lastWordTrailing
        } else { return }
        performReplace(strokes: strokes, trailingSpaces: trailing, to: other)
        wordBuffer.removeAll()
        lastWord = strokes  // повторный двойной Shift откатит обратно
        lastWordTrailing = trailing
    }

    // Стираем слово и перепечатываем его в другой раскладке
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
            func post(_ keycode: CGKeyCode, shift: Bool) {
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: down) else { continue }
                    e.flags = shift ? [.maskShift] : []
                    e.setIntegerValueField(.eventSourceUserData, value: syntheticMagic)
                    e.post(tap: .cgSessionEventTap)
                    usleep(1000)
                }
            }
            for _ in 0..<total { post(51, shift: false) }
            usleep(20000)
            DispatchQueue.main.sync { _ = TISSelectInputSource(target) }
            usleep(50000)  // даём раскладке примениться
            for s in strokes { post(s.keycode, shift: s.shift) }
            for _ in 0..<trailingSpaces { post(49, shift: false) }
            DispatchQueue.main.async { self.replaceInProgress = false }
        }
    }

    // MARK: Утилиты раскладок

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

    func sourceID(_ s: TISInputSource) -> String {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    func lang(of source: TISInputSource) -> String {
        if let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String],
           let first = langs.first {
            return first
        }
        return "en"
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
                result += String(utf16CodeUnits: chars, count: length)
            }
            return result
        }
    }

    func isValidWord(_ word: String, lang: String) -> Bool {
        guard !word.isEmpty else { return false }
        let r = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: lang,
                                                    wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
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
        if animated { showPill(style: style) }
    }

    func showPill(style: Style) {
        pillTimer?.invalidate()
        pillWindow?.orderOut(nil)

        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 92, height: 44)
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
        view.layer?.backgroundColor = style.color.withAlphaComponent(0.9).cgColor
        view.layer?.cornerRadius = 12

        let text = NSTextField(labelWithString: style.label)
        text.font = .systemFont(ofSize: 22, weight: .bold)
        text.textColor = .white
        text.alignment = .center
        text.frame = NSRect(x: 0, y: (size.height - 28) / 2, width: size.width, height: 28)
        view.addSubview(text)

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
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
