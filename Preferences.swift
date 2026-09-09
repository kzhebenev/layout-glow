import Cocoa

// Окно настроек: всё, что раньше жило в меню и текстовых файлах.
// Файлы остаются источником правды — их правка снаружи продолжает работать,
// окно просто редактирует их же.
final class PreferencesWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let delegate: AppDelegate
    private var window: NSWindow!

    private var appsTable: NSTableView!
    private var snippetsTable: NSTableView!
    private var exceptionsTable: NSTableView!
    private var hotkeysTable: NSTableView!

    private var apps: [(bundleID: String, name: String, allowed: Bool, terminal: Bool)] = []
    private var snippets: [(String, String)] = []
    private var exceptions: [String] = []
    private var hotkeys: [(String, String)] = []

    private let actionNames = ["строка", "абзац", "ключ"] + (1...9).map { "слот-\($0)" }

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
    }

    func show() {
        if window == nil { build() }
        reloadEverything()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Сборка окна

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 470),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Настройки LayoutGlow"
        window.isReleasedWhenClosed = false
        window.center()

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 720, height: 470))
        tabs.autoresizingMask = [.width, .height]
        tabs.addTabViewItem(tab("Поведение", view: behaviourView()))
        tabs.addTabViewItem(tab("Приложения", view: appsView()))
        tabs.addTabViewItem(tab("Словари", view: dictionariesView()))
        tabs.addTabViewItem(tab("Сочетания", view: hotkeysView()))
        tabs.addTabViewItem(tab("Обслуживание", view: maintenanceView()))
        window.contentView = tabs
    }

    private func tab(_ title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = title
        item.view = view
        return item
    }

    // MARK: Поведение

    private func behaviourView() -> NSView {
        let settings = Settings.shared
        let rows: [(String, String, () -> Bool, (Bool) -> Void)] = [
            ("Быстрое переключение по тапу Fn", "Мгновенно вместо системной задержки",
             { settings.fnSwitch }, { settings.fnSwitch = $0 }),
            ("Автоисправление раскладки", "Слово проверяется на пробеле и знаках препинания",
             { settings.autoCorrect }, { settings.autoCorrect = $0 }),
            ("Конвертация по двойному Shift", "Выделение или последнее слово",
             { settings.manualConvert }, { settings.manualConvert = $0 }),
            ("Откат исправления по Backspace", "Осторожно: легко спутать с обычным удалением",
             { settings.backspaceUndo }, { settings.backspaceUndo = $0 }),
            ("Только показывать, не менять текст", "Исправления пишутся в журнал, текст не трогается",
             { settings.dryRun }, { settings.dryRun = $0 }),
            ("Своя раскладка для каждого приложения", "Запоминает, на чём вы работали",
             { settings.perAppLayout }, { settings.perAppLayout = $0 }),
            ("Раскладка по типу поля", "Адресная строка отдельно от текста; в Electron работает не всегда",
             { settings.perFieldLayout }, { settings.perFieldLayout = $0 }),
            ("Подсветка Caps Lock", "Свечение меняет цвет",
             { settings.capsGlow }, { settings.capsGlow = $0 }),
            ("Ярлык раскладки у курсора", "Появляется при переключении",
             { settings.caretDot }, { settings.caretDot = $0 }),
            ("Словари в iCloud", "Общий набор на всех маках",
             { settings.iCloudSync }, { _ in self.delegate.toggleICloud() }),
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        for (index, row) in rows.enumerated() {
            let box = NSButton(checkboxWithTitle: row.0, target: self, action: #selector(behaviourToggled(_:)))
            box.state = row.2() ? .on : .off
            box.tag = index
            behaviourSetters.append(row.3)
            let hint = NSTextField(labelWithString: row.1)
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            let group = NSStackView(views: [box, hint])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 1
            group.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            stack.addArrangedSubview(group)
        }
        return wrap(stack)
    }

    private var behaviourSetters: [(Bool) -> Void] = []

    @objc private func behaviourToggled(_ sender: NSButton) {
        guard sender.tag < behaviourSetters.count else { return }
        behaviourSetters[sender.tag](sender.state == .on)
    }

    // MARK: Приложения

    private func appsView() -> NSView {
        appsTable = table(columns: [("app", "Приложение", 320), ("state", "Исправление", 150),
                                    ("kind", "Тип", 130)])
        let add = NSButton(title: "Добавить текущее", target: self, action: #selector(addCurrentApp))
        let toggle = NSButton(title: "Включить или выключить", target: self, action: #selector(toggleSelectedApp))
        let remove = NSButton(title: "Забыть", target: self, action: #selector(forgetApp))
        return listLayout(table: appsTable, buttons: [add, toggle, remove],
                          hint: "Терминалы определяются сами; ваш выбор всегда сильнее.")
    }

    @objc private func addCurrentApp() {
        guard let bid = delegate.frontApp?.bundleIdentifier else { return }
        Settings.shared.setExcluded(bid, false)
        reloadEverything()
    }

    @objc private func toggleSelectedApp() {
        let row = appsTable.selectedRow
        guard row >= 0, row < apps.count else { return }
        Settings.shared.setExcluded(apps[row].bundleID, apps[row].allowed)
        reloadEverything()
    }

    @objc private func forgetApp() {
        let row = appsTable.selectedRow
        guard row >= 0, row < apps.count else { return }
        var excluded = Settings.shared.excludedApps
        var allowed = Settings.shared.allowedApps
        excluded.remove(apps[row].bundleID)
        allowed.remove(apps[row].bundleID)
        Settings.shared.excludedApps = excluded
        Settings.shared.allowedApps = allowed
        reloadEverything()
    }

    // MARK: Словари

    private func dictionariesView() -> NSView {
        snippetsTable = table(columns: [("key", "Ключ", 120), ("value", "Текст", 280)])
        exceptionsTable = table(columns: [("word", "Слово-исключение", 200)])

        let addSnippet = NSButton(title: "Добавить", target: self, action: #selector(addSnippet))
        let editSnippet = NSButton(title: "Изменить", target: self, action: #selector(editSnippet))
        let dropSnippet = NSButton(title: "Удалить", target: self, action: #selector(removeSnippet))
        let left = listLayout(table: snippetsTable, buttons: [addSnippet, editSnippet, dropSnippet],
                              hint: "Числовые ключи 1-9 вставляются по Cmd+Option+цифра.")

        let dropException = NSButton(title: "Удалить", target: self, action: #selector(removeException))
        let openFolder = NSButton(title: "Папка словарей", target: self, action: #selector(openFolder))
        let right = listLayout(table: exceptionsTable, buttons: [dropException, openFolder],
                               hint: "Пополняется откатом по двойному Shift.")

        let split = NSStackView(views: [left, right])
        split.orientation = .horizontal
        split.distribution = .fillEqually
        split.spacing = 12
        return wrap(split)
    }

    @objc private func addSnippet() {
        guard let key = ask("Новая вставка", "Ключ, который будете набирать:"), !key.isEmpty,
              let value = ask("Новая вставка", "Что подставить вместо «\(key)»:"), !value.isEmpty else { return }
        var pairs = snippets.filter { $0.0.lowercased() != key.lowercased() }
        pairs.append((key.lowercased(), value))
        delegate.snippetsFile.replaceAll(pairs.sorted { $0.0 < $1.0 })
        reloadEverything()
    }

    @objc private func editSnippet() {
        let row = snippetsTable.selectedRow
        guard row >= 0, row < snippets.count else { return }
        let current = snippets[row]
        guard let value = ask("Изменить вставку", "Текст для ключа «\(current.0)»:", initial: current.1),
              !value.isEmpty else { return }
        var pairs = snippets
        pairs[row] = (current.0, value)
        delegate.snippetsFile.replaceAll(pairs)
        reloadEverything()
    }

    @objc private func removeSnippet() {
        let row = snippetsTable.selectedRow
        guard row >= 0, row < snippets.count else { return }
        var pairs = snippets
        pairs.remove(at: row)
        delegate.snippetsFile.replaceAll(pairs)
        reloadEverything()
    }

    @objc private func removeException() {
        let row = exceptionsTable.selectedRow
        guard row >= 0, row < exceptions.count else { return }
        delegate.exceptionsFile.remove(exceptions[row])
        reloadEverything()
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(delegate.snippetsFile.url.deletingLastPathComponent())
    }

    // MARK: Сочетания

    private func hotkeysView() -> NSView {
        hotkeysTable = table(columns: [("action", "Действие", 220), ("combo", "Сочетание", 220)])
        let edit = NSButton(title: "Изменить", target: self, action: #selector(editHotkey))
        let reset = NSButton(title: "Вернуть по умолчанию", target: self, action: #selector(resetHotkeys))
        return listLayout(table: hotkeysTable, buttons: [edit, reset],
                          hint: "Формат: cmd+opt+-, ctrl+shift+f1. Проверяется при сохранении.")
    }

    @objc private func editHotkey() {
        let row = hotkeysTable.selectedRow
        guard row >= 0, row < hotkeys.count else { return }
        let current = hotkeys[row]
        guard let combo = ask("Сочетание для «\(current.0)»",
                              "Например cmd+opt+-", initial: current.1) else { return }
        guard parseHotkey(combo) != nil else {
            let warning = NSAlert()
            warning.messageText = "Не понимаю сочетание «\(combo)»"
            warning.informativeText = "Нужен хотя бы один модификатор: cmd, opt, ctrl, shift — и клавиша."
            warning.runModal()
            return
        }
        var pairs = hotkeys
        pairs[row] = (current.0, combo)
        delegate.hotkeysFile.replaceAll(pairs)
        delegate.registerSlotHotkeys()
        reloadEverything()
    }

    @objc private func resetHotkeys() {
        let pairs = SnippetFile.parse(defaultHotkeys.joined(separator: "\n"))
        delegate.hotkeysFile.replaceAll(actionNames.compactMap { name in
            pairs[name].map { (name, $0) }
        })
        delegate.registerSlotHotkeys()
        reloadEverything()
    }

    // MARK: Обслуживание

    private func maintenanceView() -> NSView {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let title = NSTextField(labelWithString: "LayoutGlow \(version)")
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let permissions = NSTextField(labelWithString: "")
        permissions.font = .systemFont(ofSize: 12)
        permissionsLabel = permissions

        func button(_ text: String, _ selector: Selector) -> NSButton {
            let b = NSButton(title: text, target: self, action: selector)
            b.bezelStyle = .rounded
            return b
        }
        let stack = NSStackView(views: [
            title, permissions,
            button("Проверить обновления", #selector(checkUpdates)),
            button("Вернуться на предыдущую версию…", #selector(rollback)),
            button("Проверить себя сейчас", #selector(selfCheck)),
            button("История исправлений", #selector(openCorrections)),
            button("Журнал состояния", #selector(openStatus)),
            button("Разрешения системы", #selector(openPermissions)),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        return wrap(stack)
    }

    private var permissionsLabel: NSTextField?

    @objc private func checkUpdates() { delegate.checkUpdatesManually() }
    @objc private func rollback() { delegate.rollbackToPrevious() }
    @objc private func selfCheck() { delegate.runSelfCheckNow() }
    @objc private func openCorrections() { delegate.openCorrections() }
    @objc private func openStatus() {
        NSWorkspace.shared.open(supportDirectory().appendingPathComponent("status.log"))
    }
    @objc private func openPermissions() { delegate.showOnboardingFromMenu() }

    // MARK: Общее

    private func reloadEverything() {
        let settings = Settings.shared
        var seen = Set<String>()
        var list: [(String, String, Bool, Bool)] = []
        for bid in settings.excludedApps.union(settings.allowedApps).sorted() {
            guard seen.insert(bid).inserted else { continue }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
            list.append((bid, delegate.appName(for: bid),
                         !settings.excludedApps.contains(bid),
                         delegate.isTerminalLike(running)))
        }
        if let front = delegate.frontApp, let bid = front.bundleIdentifier, seen.insert(bid).inserted {
            list.append((bid, front.localizedName ?? bid,
                         delegate.correctionAllowed(in: front), delegate.isTerminalLike(front)))
        }
        apps = list
        snippets = delegate.snippetsFile.items.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        exceptions = delegate.exceptionsFile.words.sorted()
        hotkeys = actionNames.map { ($0, delegate.hotkeysFile.value(for: $0) ?? "не задано") }

        appsTable?.reloadData()
        snippetsTable?.reloadData()
        exceptionsTable?.reloadData()
        hotkeysTable?.reloadData()
        permissionsLabel?.stringValue =
            "Мониторинг ввода: \(delegate.eventTap != nil ? "выдан" : "НЕ ВЫДАН")   "
            + "Универсальный доступ: \(AXIsProcessTrusted() ? "выдан" : "НЕ ВЫДАН")"
        permissionsLabel?.textColor = (delegate.eventTap != nil && AXIsProcessTrusted())
            ? .secondaryLabelColor : .systemOrange
    }

    private func ask(_ title: String, _ question: String, initial: String = "") -> String? {
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.informativeText = question
        dialog.addButton(withTitle: "Сохранить")
        dialog.addButton(withTitle: "Отмена")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = initial
        dialog.accessoryView = field
        dialog.window.initialFirstResponder = field
        guard dialog.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private func table(columns: [(String, String, CGFloat)]) -> NSTableView {
        let view = NSTableView()
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            view.addTableColumn(column)
        }
        view.dataSource = self
        view.delegate = self
        view.usesAlternatingRowBackgroundColors = true
        view.rowHeight = 20
        return view
    }

    private func listLayout(table: NSTableView, buttons: [NSButton], hint: String) -> NSView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        buttons.forEach { $0.bezelStyle = .rounded }

        let note = NSTextField(labelWithString: hint)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [scroll, row, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        return stack
    }

    private func wrap(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        return container
    }

    // MARK: Данные таблиц

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case appsTable: return apps.count
        case snippetsTable: return snippets.count
        case exceptionsTable: return exceptions.count
        case hotkeysTable: return hotkeys.count
        default: return 0
        }
    }

    func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        let id = column?.identifier.rawValue ?? ""
        switch tableView {
        case appsTable:
            let app = apps[row]
            switch id {
            case "app": return app.name
            case "state": return app.allowed ? "исправляет" : "выключено"
            default: return app.terminal ? "терминал" : ""
            }
        case snippetsTable:
            return id == "key" ? snippets[row].0 : snippets[row].1
        case exceptionsTable:
            return exceptions[row]
        case hotkeysTable:
            return id == "action" ? hotkeys[row].0 : hotkeys[row].1
        default: return nil
        }
    }
}
