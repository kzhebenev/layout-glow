import AppKit
import Carbon

// MARK: - Клавиши и раскладки

struct Stroke {
    let keycode: CGKeyCode
    let shift: Bool
    let caps: Bool
}

// Дефис и апостроф внутри слова допустимы: «дабл-шифт» разбирается по частям
let wordSeparators: Set<Character> = ["-", "'", "\u{2019}"]

// Знаки, на которых слово считается законченным и проверяется
let boundaryChars: Set<Character> = [",", ";", "!", "?", ")", "]", "}", "\u{00AB}", "\u{00BB}"]

// Знаки, встречающиеся внутри путей, доменов и адресов: на них слово
// не проверяется, чтобы не калечить «com.apple» и «kz@devkz.ru»
let identifierChars: Set<Character> = [".", "/", ":", "@", "_", "\\", "#", "&", "=", "+", "~", "%", "$"]

// Спеллчекер считает валидной любую одиночную букву,
// поэтому однобуквенные слова разрешены только по списку
let singleLetterWords: [String: Set<String>] = [
    "ru": ["я", "в", "и", "к", "с", "у", "а", "о"],
    "en": ["a", "i"],
]

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

func layout(withID id: String) -> TISInputSource? {
    enabledLayouts().first(where: { sourceID($0) == id })
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
            if let cf = from.first, let ct = to.first, from.count == 1, to.count == 1, cf != ct {
                map[cf] = ct
            }
        }
    }
    return map
}

// MARK: - Разбор слов

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

// Только буквы (плюс дефис и апостроф) — значит, это слово,
// а не часть пути, адреса или команды с аргументами
func isPureWord(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy { $0.isLetter || wordSeparators.contains($0) }
}

// Отделяет хвост из знаков препинания: «привет...» -> («привет», «...»)
func trailingPunctuation(_ s: String) -> (word: String, tail: String) {
    var word = s
    var tail = ""
    while let last = word.last, !last.isLetter, !wordSeparators.contains(last) {
        tail.insert(last, at: tail.startIndex)
        word.removeLast()
    }
    return (word, tail)
}

// Какими клавишами набрать этот символ в указанной раскладке
func stroke(for character: Character, in source: TISInputSource) -> Stroke? {
    let target = String(character)
    for code in 0...50 {
        for shift in [false, true] {
            let s = Stroke(keycode: CGKeyCode(code), shift: shift, caps: false)
            if translate([s], via: source) == target { return s }
        }
    }
    return nil
}

func wordParts(_ s: String) -> [String] {
    s.split(whereSeparator: { wordSeparators.contains($0) }).map(String.init)
}

// Осмысленно ли это на данном языке: каждая часть — словарное слово,
// системная команда или однобуквенное слово из списка
func meaningful(_ s: String, lang: String, commands: Set<String> = []) -> Bool {
    let base = String(lang.prefix(2)).lowercased()
    let parts = wordParts(s)
    guard !parts.isEmpty else { return false }
    return parts.allSatisfy { part in
        let lower = part.lowercased()
        if commands.contains(lower) { return true }
        if part.count == 1 { return singleLetterWords[base]?.contains(lower) ?? false }
        return isValidWord(part, lang: lang)
    }
}

// MARK: - Решение об автоисправлении

struct Decision {
    let correct: Bool
    let reason: String
}

func correctionDecision(typed: String, converted: String,
                        srcLang: String, dstLang: String,
                        commands: Set<String> = [], exceptions: Set<String> = [],
                        capsOn: Bool = false) -> Decision {
    if exceptions.contains(typed.lowercased()) {
        return Decision(correct: false, reason: "в списке исключений")
    }
    // Аббревиатура (HD, СКЗИ): всё заглавными и Caps Lock не был включён
    if !capsOn, typed.rangeOfCharacter(from: .letters) != nil, typed == typed.uppercased() {
        return Decision(correct: false, reason: "аббревиатура")
    }
    guard isWordLike(converted) else {
        return Decision(correct: false, reason: "не слово целиком")
    }
    if meaningful(typed, lang: srcLang, commands: commands) {
        return Decision(correct: false, reason: "валидно в \(srcLang)")
    }
    guard meaningful(converted, lang: dstLang, commands: commands) else {
        return Decision(correct: false, reason: "«\(converted)» невалидно в \(dstLang)")
    }
    return Decision(correct: true, reason: "исправлено")
}

// MARK: - Файловые словари

func supportDirectory() -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LayoutGlow")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// Папка в iCloud Drive: словари, общие для всех маков
func iCloudDirectory() -> URL? {
    let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    guard FileManager.default.fileExists(atPath: base.path) else { return nil }
    let dir = base.appendingPathComponent("LayoutGlow")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// Куда класть словари сейчас: локально или в iCloud
func dictionaryDirectory(iCloud: Bool) -> URL {
    (iCloud ? iCloudDirectory() : nil) ?? supportDirectory()
}

// Список слов: по строке на слово, «#» — комментарий. Перечитывается при изменении файла.
final class WordFile {
    let url: URL
    private let header: String
    private var mtime: Date?
    private(set) var words: Set<String> = []

    init(name: String, header: String, defaults: [String] = [], directory: URL? = nil) {
        self.url = (directory ?? supportDirectory()).appendingPathComponent(name)
        self.header = header
        if !FileManager.default.fileExists(atPath: url.path) {
            let body = ([header] + defaults).joined(separator: "\n") + "\n"
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
        reload(force: true)
    }

    func reload(force: Bool = false) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attrs?[.modificationDate] as? Date
        if !force, let modified, let mtime, modified == mtime { return }
        mtime = modified
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        words = Set(text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.lowercased() })
    }

    func add(_ word: String) {
        let w = word.lowercased()
        guard !words.contains(w) else { return }
        words.insert(w)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write((w + "\n").data(using: .utf8)!)
            try? handle.close()
            mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
    }

    func remove(_ word: String) {
        let w = word.lowercased()
        words.remove(w)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).lowercased() != w }
        try? (kept.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
        reload(force: true)
    }
}

// Словарь вставок: строки вида «ключ = текст»
final class SnippetFile {
    let url: URL
    private var mtime: Date?
    private(set) var items: [String: String] = [:]

    init(name: String, header: String, defaults: [String] = [], directory: URL? = nil) {
        self.url = (directory ?? supportDirectory()).appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            let body = ([header] + defaults).joined(separator: "\n") + "\n"
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
        reload(force: true)
    }

    func reload(force: Bool = false) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attrs?[.modificationDate] as? Date
        if !force, let modified, let mtime, modified == mtime { return }
        mtime = modified
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        items = SnippetFile.parse(text)
    }

    static func parse(_ text: String) -> [String: String] {
        var result = [String: String]()
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty { result[key] = value }
        }
        return result
    }

    func value(for key: String) -> String? { items[key.lowercased()] }

    // true, если файл изменился с прошлой проверки (нужно перерегистрировать сочетания)
    func reloadIfChanged() -> Bool {
        let before = items
        reload()
        return before != items
    }
}

// MARK: - Списки по умолчанию

let defaultCommands = [
    "ls", "cd", "pwd", "cp", "mv", "rm", "mkdir", "rmdir", "touch", "cat", "less", "more", "head", "tail",
    "grep", "egrep", "fgrep", "ripgrep", "rg", "find", "fd", "locate", "which", "whereis", "file", "stat",
    "chmod", "chown", "chgrp", "ln", "df", "du", "mount", "umount", "diskutil", "hdiutil", "fsck",
    "ps", "top", "htop", "kill", "killall", "pkill", "pgrep", "jobs", "bg", "fg", "nohup", "nice", "renice",
    "sudo", "su", "whoami", "id", "groups", "passwd", "chsh", "login", "logout", "exit",
    "echo", "printf", "read", "export", "env", "set", "unset", "alias", "unalias", "source", "eval",
    "sed", "awk", "cut", "sort", "uniq", "tr", "wc", "tee", "xargs", "diff", "patch", "comm", "join", "paste",
    "tar", "gzip", "gunzip", "zip", "unzip", "bzip2", "xz", "zstd",
    "curl", "wget", "ssh", "scp", "sftp", "rsync", "ping", "traceroute", "netstat", "lsof", "dig", "nslookup",
    "host", "ifconfig", "ipconfig", "route", "arp", "nc", "telnet", "iptables", "ufw", "openssl", "ssh-keygen",
    "git", "svn", "hg", "make", "cmake", "gcc", "clang", "swift", "swiftc", "xcodebuild", "xcrun", "lldb",
    "python", "python3", "pip", "pip3", "node", "npm", "npx", "yarn", "pnpm", "deno", "bun",
    "ruby", "gem", "bundle", "rails", "php", "composer", "java", "javac", "gradle", "maven", "mvn",
    "go", "cargo", "rustc", "rustup", "dotnet", "perl", "lua", "julia",
    "docker", "docker-compose", "podman", "kubectl", "helm", "minikube", "kubectx", "kubens",
    "terraform", "ansible", "vagrant", "packer", "pulumi",
    "brew", "port", "apt", "apt-get", "dpkg", "yum", "dnf", "rpm", "pacman", "snap", "flatpak",
    "systemctl", "service", "journalctl", "systemd", "launchctl", "crontab", "at", "screen", "tmux",
    "vim", "vi", "nvim", "nano", "emacs", "code", "open", "pbcopy", "pbpaste", "say", "defaults",
    "man", "info", "help", "history", "clear", "reset", "date", "cal", "uptime", "uname", "hostname",
    "sleep", "watch", "time", "timeout", "seq", "yes", "true", "false", "test",
    "jq", "yq", "sqlite3", "psql", "mysql", "mongo", "redis-cli",
    "softwareupdate", "spctl", "codesign", "xattr", "plutil", "networksetup", "scutil", "sw_vers",
    "caffeinate", "pmset", "system_profiler", "ioreg", "log", "dtrace", "sysctl", "tccutil",
]

let defaultSnippets = [
    "# Вставки: «ключ = текст». Наберите ключ и нажмите Cmd+Option+0.",
    "# Числовые ключи 1-9 вставляются по Cmd+Option+цифра.",
    "кж = Константин Жебенев",
    "1 = kz@devkz.ru",
]

let exceptionsHeader = "# Слова, которые автоисправление не трогает. По строке на слово."
let commandsHeader = "# Системные команды: считаются словами, чтобы «пкуз» превращалось в «grep»."

// MARK: - Разбор сочетаний клавиш

// Клавиши по именам: коды виртуальных клавиш не зависят от раскладки
let namedKeycodes: [String: UInt32] = [
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
    "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1,
    "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    "-": 27, "минус": 27, "=": 24, "равно": 24, "[": 33, "]": 30, ";": 41, "'": 39,
    ",": 43, ".": 47, "/": 44, "`": 50,
    "space": 49, "пробел": 49, "return": 36, "ввод": 36, "tab": 48, "escape": 53, "esc": 53,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

struct Hotkey: Equatable {
    let keycode: UInt32
    let modifiers: UInt32
}

// «cmd+opt+-» -> код клавиши и модификаторы Carbon
func parseHotkey(_ text: String) -> Hotkey? {
    let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let keyName = parts.last, !keyName.isEmpty else { return nil }
    var modifiers: UInt32 = 0
    for part in parts.dropLast() {
        switch part {
        case "cmd", "command", "команда": modifiers |= UInt32(cmdKey)
        case "opt", "option", "alt", "альт": modifiers |= UInt32(optionKey)
        case "ctrl", "control", "контрол": modifiers |= UInt32(controlKey)
        case "shift", "шифт": modifiers |= UInt32(shiftKey)
        default: return nil
        }
    }
    guard modifiers != 0, let keycode = namedKeycodes[keyName] else { return nil }
    return Hotkey(keycode: keycode, modifiers: modifiers)
}

// MARK: - Списки по умолчанию для правил и сочетаний

let defaultHotkeys = [
    "# Сочетания: «действие = клавиши». Модификаторы: cmd, opt, ctrl, shift.",
    "# Действия: строка, абзац, ключ, слот-1 ... слот-9.",
    "строка = cmd+opt+-",
    "абзац = cmd+opt+=",
    "ключ = cmd+opt+0",
    "слот-1 = cmd+opt+1",
    "слот-2 = cmd+opt+2",
    "слот-3 = cmd+opt+3",
    "слот-4 = cmd+opt+4",
    "слот-5 = cmd+opt+5",
    "слот-6 = cmd+opt+6",
    "слот-7 = cmd+opt+7",
    "слот-8 = cmd+opt+8",
    "слот-9 = cmd+opt+9",
]

let defaultLayoutRules = [
    "# Правила раскладки: «идентификатор приложения = язык» (ru, en).",
    "# Правило сильнее запоминания: приложение всегда получит указанный язык.",
    "com.apple.Terminal = en",
    "com.googlecode.iterm2 = en",
    "com.termius.mac = en",
    "com.apple.dt.Xcode = en",
    "com.microsoft.VSCode = en",
]
