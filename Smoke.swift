import Cocoa
import Carbon

// Дымовые тесты на живом текстовом поле: приложение печатает само себе
// и проверяет, что получилось. Ловит то, что чистые тесты поймать не могут,
// — взаимодействие с реальным полем ввода, вставку, удаление, раскладки.
// Запуск: ./run-smoke.sh

final class SmokeTest {
    struct Scenario {
        let name: String
        let language: String      // в какой раскладке печатать
        let input: String
        let expected: String
        let doubleShift: Bool     // конвертировать двойным Shift вместо пробела
    }

    let delegate: AppDelegate
    var window: NSWindow!
    var field: NSTextField!
    var failures = 0
    var transcript: [String] = []

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    let scenarios: [Scenario] = [
        Scenario(name: "обычное слово", language: "en", input: "ghbdtn ", expected: "привет ", doubleShift: false),
        Scenario(name: "слово с «ж» на месте точки с запятой", language: "en",
                 input: "ghjljk;fq ", expected: "продолжай ", doubleShift: false),
        Scenario(name: "правильное слово не трогаем", language: "en",
                 input: "hello ", expected: "hello ", doubleShift: false),
        Scenario(name: "ссылка остаётся латиницей", language: "en",
                 input: "http://vk.com ", expected: "http://vk.com ", doubleShift: false),
        Scenario(name: "адрес IPv4", language: "ru", input: "192ю168ю2ю1 ", expected: "192.168.2.1 ", doubleShift: false),
        Scenario(name: "знак после слова", language: "en", input: "ghbdtn!", expected: "привет!", doubleShift: false),
        Scenario(name: "запятая границей не считается", language: "en",
                 input: "ghbdtn,", expected: "ghbdtn,", doubleShift: false),
        Scenario(name: "конвертация двойным Shift", language: "en",
                 input: "rjirf", expected: "кошка", doubleShift: true),
    ]

    func run() {
        buildWindow()
        DispatchQueue.global(qos: .userInitiated).async {
            usleep(700000)
            guard self.ensureFocus() else {
                self.say("ПРОВАЛ: тестовое окно не получило фокус — печатать вслепую нельзя")
                DispatchQueue.main.async { exit(1) }
                return
            }
            let state = DispatchQueue.main.sync { () -> String in
                let trusted = AXIsProcessTrusted()
                let key = self.window.isKeyWindow
                let responder = (self.window.firstResponder as? NSText) != nil
                    || self.window.firstResponder === self.field
                    || (self.window.firstResponder is NSTextView)
                return "доступ: \(trusted), окно активно: \(key), фокус в поле: \(responder), "
                    + "перехват: \(self.delegate.eventTap != nil)"
            }
            self.say("состояние — " + state)
            for scenario in self.scenarios { self.execute(scenario) }
            let events = DispatchQueue.main.sync { self.delegate.events }
            if self.failures > 0 {
                self.say("--- журнал приложения ---")
                for line in events.suffix(20) { self.say(line) }
            }
            DispatchQueue.main.async {
                self.say(self.failures == 0
                         ? "Дымовые тесты пройдены: \(self.scenarios.count)"
                         : "Провалено \(self.failures) из \(self.scenarios.count)")
                exit(self.failures == 0 ? 0 : 1)
            }
        }
    }

    // Без меню «Правка» AppKit не обрабатывает Cmd+V, и вставка
    // в тестовом окне не срабатывала бы — приложение тут ни при чём
    func buildMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Правка")
        edit.addItem(NSMenuItem(title: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func buildWindow() {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 90),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "LayoutGlow: дымовые тесты"
        field = NSTextField(frame: NSRect(x: 20, y: 25, width: 480, height: 34))
        field.font = .systemFont(ofSize: 15)
        window.contentView?.addSubview(field)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(field)
        // Иначе исправления будут сверяться с приложением, которое было впереди
        delegate.frontApp = NSRunningApplication.current
    }

    // Печатать можно только когда наше окно действительно активно:
    // иначе нажатия уйдут в чужое приложение и оно получит правки
    @discardableResult
    func ensureFocus() -> Bool {
        for _ in 0..<30 {
            let ready = DispatchQueue.main.sync { () -> Bool in
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(field)
                return window.isKeyWindow
            }
            if ready { return true }
            usleep(100000)
        }
        return false
    }

    func execute(_ scenario: Scenario) {
        guard ensureFocus() else {
            report(scenario, actual: "окно не активно", passed: false)
            return
        }
        // Списки раскладок и разбор символов — только с главного потока:
        // TISCreateInputSourceList проверяет очередь и роняет процесс
        let prepared: [Stroke]? = DispatchQueue.main.sync {
            guard let layout = delegate.source(forLanguage: scenario.language) else { return nil }
            TISSelectInputSource(layout)
            field.stringValue = ""
            window.makeFirstResponder(field)
            delegate.wordBuffer.removeAll()
            delegate.lastWord = nil
            return scenario.input.map { character in
                character == " "
                    ? Stroke(keycode: 49, shift: false, caps: false)
                    : (stroke(for: character, in: layout) ?? Stroke(keycode: 49, shift: false, caps: false))
            }
        }
        guard let strokes = prepared else {
            report(scenario, actual: "нет раскладки \(scenario.language)", passed: false)
            return
        }
        usleep(300000)

        for s in strokes {
            postRaw(s.keycode, flags: s.shift ? [.maskShift] : [])
            usleep(25000)
        }
        if scenario.doubleShift { tapShiftTwice() }
        usleep(900000)

        let actual = DispatchQueue.main.sync { field.stringValue }
        report(scenario, actual: actual, passed: actual == scenario.expected)
    }

    // Печатаем как человек: без метки синтетического события,
    // иначе приложение проигнорирует собственный ввод
    func postRaw(_ keycode: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cgSessionEventTap)
            usleep(3000)
        }
    }

    func tapShiftTwice() {
        for _ in 0..<2 {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: down) else { continue }
                event.flags = down ? [.maskShift] : []
                event.post(tap: .cgSessionEventTap)
                usleep(20000)
            }
            usleep(80000)
        }
    }

    func report(_ scenario: Scenario, actual: String, passed: Bool) {
        if passed {
            say("ок: \(scenario.name)")
        } else {
            failures += 1
            say("ПРОВАЛ: \(scenario.name) — ожидалось «\(scenario.expected)», получено «\(actual)»")
        }
    }

    // Результаты пишем в файл: приложение запускается через open,
    // иначе macOS не считает его владельцем разрешений, и вывод в консоль
    // до запускавшего скрипта не доходит
    func say(_ line: String) {
        transcript.append(line)
        let path = supportDirectory().appendingPathComponent("smoke.log")
        try? transcript.joined(separator: "\n").appending("\n").write(to: path, atomically: true, encoding: .utf8)
        print(line)
    }
}
