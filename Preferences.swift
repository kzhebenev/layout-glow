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
    private var presetsTable: NSTableView!

    private var apps: [(bundleID: String, name: String, mode: String, terminal: Bool)] = []
    private var snippets: [(String, String)] = []
    private var exceptions: [String] = []
    private var hotkeys: [(String, String)] = []
    private var presets: [(String, String)] = []

    private let actionNames = ["строка", "абзац", "ключ", "буфер"]
        + (1...9).map { "слот-\($0)" } + (1...10).map { "пресет-\($0)" }

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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.minSize = NSSize(width: 700, height: 460)
        window.title = "Настройки LayoutGlow"
        window.isReleasedWhenClosed = false
        window.center()

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 720, height: 470))
        tabs.autoresizingMask = [.width, .height]
        tabs.addTabViewItem(tab("Поведение", view: behaviourView()))
        tabs.addTabViewItem(tab("Приложения", view: appsView()))
        tabs.addTabViewItem(tab("Словари", view: dictionariesView()))
        tabs.addTabViewItem(tab("Пресеты", view: presetsView()))
        tabs.addTabViewItem(tab("Сочетания", view: hotkeysView()))
        tabs.addTabViewItem(tab("Обслуживание", view: maintenanceView()))
        tabs.addTabViewItem(tab("Справка", view: helpView()))
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
            ("Откат исправления по Backspace", "Нужно нажать дважды: первый Backspace просто стирает пробел",
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
            ("История буфера обмена", "Записи из менеджеров паролей не сохраняются",
             { settings.clipboardHistory }, { settings.clipboardHistory = $0 }),
            ("Словари в iCloud", "Общий набор на всех маках",
             { settings.iCloudSync }, { _ in self.delegate.toggleICloud() }),
        ]

        let left = NSStackView()
        let right = NSStackView()
        for column in [left, right] {
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 12
        }

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
            (index < (rows.count + 1) / 2 ? left : right).addArrangedSubview(group)
        }
        // Без распорки внизу галочки растягиваются по всей высоте
        for column in [left, right] {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
            column.addArrangedSubview(spacer)
        }
        let columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 24
        columns.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        return wrap(columns)
    }

    private var behaviourSetters: [(Bool) -> Void] = []

    @objc private func behaviourToggled(_ sender: NSButton) {
        guard sender.tag < behaviourSetters.count else { return }
        behaviourSetters[sender.tag](sender.state == .on)
    }

    // MARK: Приложения

    private func appsView() -> NSView {
        appsTable = table(columns: [("app", "Приложение", 300), ("state", "Режим", 170),
                                    ("kind", "Тип", 130)])
        let add = NSButton(title: "Добавить текущее", target: self, action: #selector(addCurrentApp))
        let toggle = NSButton(title: "Сменить режим", target: self, action: #selector(toggleSelectedApp))
        let remove = NSButton(title: "Забыть", target: self, action: #selector(forgetApp))
        return listLayout(table: appsTable, buttons: [add, toggle, remove],
                          hint: "Режимы: полностью, вручную (работают только жесты), выключено. "
                              + "Терминалы по умолчанию получают «вручную»: в оболочке правка портит ввод.")
    }

    @objc private func addCurrentApp() {
        guard let bid = delegate.frontApp?.bundleIdentifier else { return }
        delegate.setMode(.full, for: bid)
        reloadEverything()
    }

    @objc private func toggleSelectedApp() {
        let row = appsTable.selectedRow
        guard row >= 0, row < apps.count else { return }
        let bundleID = apps[row].bundleID
        let current = delegate.mode(forBundleID: bundleID)
        delegate.setMode(delegate.nextMode(after: current), for: bundleID)
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

    // MARK: Пресеты

    private func presetsView() -> NSView {
        presetsTable = table(columns: [("number", "Номер", 80), ("text", "Текст", 380),
                                       ("combo", "Сочетание", 160)])
        let edit = NSButton(title: "Изменить", target: self, action: #selector(editPreset))
        let clear = NSButton(title: "Очистить", target: self, action: #selector(clearPreset))
        return listLayout(table: presetsTable, buttons: [edit, clear],
                          hint: "Десять пресетов на Ctrl+Option+Cmd+цифра; сочетания меняются на вкладке «Сочетания».")
    }

    @objc private func editPreset() {
        let row = presetsTable.selectedRow
        guard row >= 0, row < presets.count else { return }
        let current = presets[row]
        guard let value = ask("Пресет \(current.0)", "Что вставлять:", initial: current.1), !value.isEmpty else { return }
        var pairs = presets.map { ($0.0, $0.1) }.filter { !$0.1.isEmpty }
        if let index = pairs.firstIndex(where: { $0.0 == current.0 }) {
            pairs[index] = (current.0, value)
        } else {
            pairs.append((current.0, value))
        }
        delegate.presetsFile.replaceAll(pairs.sorted { (Int($0.0) ?? 0) < (Int($1.0) ?? 0) })
        reloadEverything()
    }

    @objc private func clearPreset() {
        let row = presetsTable.selectedRow
        guard row >= 0, row < presets.count else { return }
        let pairs = presets.map { ($0.0, $0.1) }
            .filter { $0.0 != presets[row].0 && !$0.1.isEmpty }
        delegate.presetsFile.replaceAll(pairs)
        reloadEverything()
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
            button("Очистить историю буфера обмена", #selector(clearClipboard)),
            button("Журнал состояния", #selector(openStatus)),
            button("Разрешения системы", #selector(openPermissions)),
            button("Выдать разрешения заново", #selector(repairPermissions)),
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
    @objc private func clearClipboard() {
        delegate.clipboard?.clear()
        let done = NSAlert()
        done.messageText = "История буфера обмена очищена"
        done.runModal()
    }
    @objc private func openStatus() {
        NSWorkspace.shared.open(runtimeDirectory().appendingPathComponent("status.log"))
    }
    @objc private func openPermissions() { delegate.showOnboardingFromMenu() }
    @objc private func repairPermissions() { delegate.repairPermissions() }

    // Снимок каждой вкладки: смотреть на интерфейс со стороны полезнее,
    // чем верить, что раскладка сложилась правильно
    func snapshotAllTabs() {
        guard let tabs = window?.contentView as? NSTabView else { return }
        let selected = tabs.selectedTabViewItem
        for (index, item) in tabs.tabViewItems.enumerated() {
            tabs.selectTabViewItem(item)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let name = "tab-\(index)-\(item.label)".replacingOccurrences(of: " ", with: "-")
            try? data.write(to: runtimeDirectory().appendingPathComponent("snapshot-\(name).png"))
        }
        if let selected { tabs.selectTabViewItem(selected) }
    }

    // MARK: Справка

    private func helpView() -> NSView {
        let container = NSView()

        let text = NSTextView()
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 14, height: 12)
        text.textStorage?.setAttributedString(helpText())

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        func button(_ title: String, _ selector: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: selector)
            b.bezelStyle = .rounded
            return b
        }
        let row = NSStackView(views: [
            button("Сочетания…", #selector(openShortcutsWindow)),
            button("Разрешения…", #selector(openPermissions)),
            button("Страница проекта", #selector(openProjectPage)),
            button("Лицензия", #selector(openLicense)),
        ])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let footer = NSTextField(labelWithString:
            "LayoutGlow \(version). © 2026 Константин Жебенев. Лицензия MIT — пользуйтесь и меняйте свободно.")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            row.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        return container
    }

    private func helpText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        func heading(_ text: String) {
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        func body(_ text: String) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 10
            style.lineSpacing = 2
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]))
        }

        heading("Что видно на экране")
        body("Свечение вдоль нижнего края показывает раскладку: оранжевое — русская, синее — английская, "
             + "красное — включён Caps Lock. При переключении рядом с курсором всплывает ярлык, "
             + "а текущая раскладка всегда видна в строке меню.")

        heading("Переключение")
        body("Тап по клавише Fn меняет раскладку мгновенно — системную задержку это обходит. "
             + "Чтобы работало, в системных настройках клавиатуры «Press Globe key to» должно стоять «Do Nothing». "
             + "Приложение умеет запоминать раскладку для каждой программы, а правила в файле layout-rules.txt "
             + "задают её жёстко: например, в терминале всегда английская.")

        heading("Исправление раскладки")
        body("Слово проверяется, когда вы ставите пробел или знак вроде запятой и восклицательного знака. "
             + "Если набранное бессмысленно, а в другой раскладке получается словарное слово, оно заменяется само. "
             + "Двойной Shift конвертирует выделенный текст, а без выделения — слово, которое вы набираете "
             + "или набрали последним. Повторный двойной Shift после исправления возвращает написание "
             + "и заносит слово в исключения навсегда.")

        heading("Что остаётся нетронутым")
        body("Поля для паролей, включая веб-формы под звёздочками. Ссылки, адреса почты и пути. "
             + "Аббревиатуры заглавными буквами. Слова из файла исключений. Приложения, для которых вы "
             + "выключили исправление; незнакомые терминалы выключаются сами. "
             + "IP-адреса, наоборот, чинятся: «192ю168ю2ю1» станет «192.168.2.1».")

        heading("Вставки, пресеты и буфер обмена")
        body("Ключ из словаря вставок разворачивается в текст по Cmd+Option+0: наберите «кж» и нажмите сочетание. "
             + "Десять пресетов вставляются по Ctrl+Option+Cmd+цифра. "
             + "История буфера обмена открывается по Ctrl+Option+Cmd+V: цифры 1-9 вставляют запись, Esc закрывает. "
             + "Записи из менеджеров паролей в историю не попадают.")

        heading("Если что-то пошло не так")
        body("На вкладке «Обслуживание» есть история исправлений — там видно, что и где менялось и не сорвалась ли "
             + "замена. Там же журнал состояния, кнопка самопроверки и возврат на предыдущую версию. "
             + "Режим «только показывать» на вкладке «Поведение» даёт посмотреть, что приложение сделало бы, "
             + "не трогая текст.")

        heading("Обновления")
        body("Приложение проверяет релизы при запуске и обновляется само. После обновления оно дожидается, "
             + "когда вы отойдёте от компьютера, прогоняет самопроверку и при неудаче возвращается на прошлую версию.")

        return result
    }

    @objc private func openShortcutsWindow() { delegate.showShortcuts() }
    @objc private func openProjectPage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/kzhebenev/layout-glow")!)
    }
    @objc private func openLicense() {
        if let bundled = Bundle.main.url(forResource: "LICENSE", withExtension: nil) {
            NSWorkspace.shared.open(bundled)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/kzhebenev/layout-glow/blob/main/LICENSE")!)
        }
    }

    // MARK: Общее

    private func reloadEverything() {
        let settings = Settings.shared
        var seen = Set<String>()
        var list: [(String, String, String, Bool)] = []
        let known = settings.excludedApps.union(settings.allowedApps).union(settings.appModes.keys)
        for bid in known.sorted() {
            guard seen.insert(bid).inserted else { continue }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
            list.append((bid, delegate.appName(for: bid),
                         delegate.mode(forBundleID: bid).rawValue,
                         delegate.isTerminalLike(bundleID: bid) || delegate.isTerminalLike(running)))
        }
        if let front = delegate.frontApp, let bid = front.bundleIdentifier, seen.insert(bid).inserted {
            list.append((bid, front.localizedName ?? bid,
                         delegate.mode(for: front).rawValue, delegate.isTerminalLike(front)))
        }
        apps = list
        snippets = delegate.snippetsFile.items.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        exceptions = delegate.exceptionsFile.words.sorted()
        hotkeys = actionNames.map { ($0, delegate.hotkeysFile.value(for: $0) ?? "не задано") }
        presets = (1...10).map { number in
            (String(number), delegate.presetsFile.value(for: String(number)) ?? "")
        }

        appsTable?.reloadData()
        presetsTable?.reloadData()
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
        view.rowHeight = 22
        view.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        view.style = .inset
        return view
    }

    // Таблица занимает всё свободное место, кнопки и подпись прижаты книзу.
    // Стеком это не получалось: таблица без своей высоты схлопывалась
    private func listLayout(table: NSTableView, buttons: [NSButton], hint: String) -> NSView {
        let container = NSView()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        buttons.forEach { $0.bezelStyle = .rounded }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        let note = NSTextField(labelWithString: hint)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(note)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -12),

            row.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -8),

            note.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            note.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            note.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        return container
    }

    // Содержимое вкладки должно занимать её целиком, иначе таблицы
    // жмутся в угол и колонки обрезаются
    private func wrap(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
        case presetsTable: return presets.count
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
            case "state": return app.mode
            default: return app.terminal ? "терминал" : ""
            }
        case snippetsTable:
            return id == "key" ? snippets[row].0 : snippets[row].1
        case exceptionsTable:
            return exceptions[row]
        case hotkeysTable:
            return id == "action" ? hotkeys[row].0 : hotkeys[row].1
        case presetsTable:
            let preset = presets[row]
            switch id {
            case "number": return preset.0
            case "text": return preset.1.isEmpty ? "—" : preset.1
            default: return delegate.hotkeysFile.value(for: "пресет-\(preset.0)") ?? ""
            }
        default: return nil
        }
    }
}
