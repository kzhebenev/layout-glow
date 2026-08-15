import AppKit
import Carbon

// Тесты логики автоисправления и словарей: ./run-tests.sh

var failures = 0
var checks = 0

func check(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition {
        failures += 1
        print("ПРОВАЛ: \(name)")
    }
}

func expect(typed: String, converted: String, src: String, dst: String,
            correct: Bool, commands: Set<String> = [], exceptions: Set<String> = [],
            capsOn: Bool = false) {
    let d = correctionDecision(typed: typed, converted: converted, srcLang: src, dstLang: dst,
                               commands: commands, exceptions: exceptions, capsOn: capsOn)
    check(d.correct == correct,
          "«\(typed)» -> «\(converted)»: ожидалось \(correct ? "исправить" : "пропустить"), получено \(d.correct ? "исправить" : "пропустить") (\(d.reason))")
}

// Обычные слова
expect(typed: "ghbdtn", converted: "привет", src: "en", dst: "ru", correct: true)
expect(typed: "ytn", converted: "нет", src: "en", dst: "ru", correct: true)
expect(typed: "утеук", converted: "enter", src: "ru", dst: "en", correct: true)
expect(typed: "сейчас", converted: "ctqxfc", src: "ru", dst: "en", correct: false)
expect(typed: "hello", converted: "руддщ", src: "en", dst: "ru", correct: false)

// Короткие слова
expect(typed: "yt", converted: "не", src: "en", dst: "ru", correct: true)
expect(typed: "z", converted: "я", src: "en", dst: "ru", correct: true)
expect(typed: "ф", converted: "a", src: "ru", dst: "en", correct: true)
expect(typed: "a", converted: "ф", src: "en", dst: "ru", correct: false)
expect(typed: "x", converted: "ч", src: "en", dst: "ru", correct: false)
expect(typed: "on", converted: "щт", src: "en", dst: "ru", correct: false)

// Дефис и апостроф (слова берём словарные: «дабл» и подобные системный
// спеллчекер признаёт не всегда, и тест начинает мигать)
expect(typed: "ghbdtn-rfr", converted: "привет-как", src: "en", dst: "ru", correct: true)
expect(typed: "ytn-ytn", converted: "нет-нет", src: "en", dst: "ru", correct: true)
expect(typed: "ghbdtn.rfr", converted: "привет.как", src: "en", dst: "ru", correct: false)

// Аббревиатуры и исключения
expect(typed: "HD", converted: "РД", src: "en", dst: "ru", correct: false)
expect(typed: "СКЗИ", converted: "CRPB", src: "ru", dst: "en", correct: false)
expect(typed: "ghbdtn", converted: "привет", src: "en", dst: "ru", correct: false,
       exceptions: ["ghbdtn"])

// Системные команды (kubectl в словарях спеллчекера отсутствует, в отличие от grep)
expect(typed: "лгиусед", converted: "kubectl", src: "ru", dst: "en", correct: true,
       commands: ["kubectl"])
expect(typed: "лгиусед", converted: "kubectl", src: "ru", dst: "en", correct: false)
expect(typed: "пкуз", converted: "grep", src: "ru", dst: "en", correct: true,
       commands: ["grep"])
expect(typed: "ls", converted: "ды", src: "en", dst: "ru", correct: false,
       commands: ["ls"])
expect(typed: "лы", converted: "ls", src: "ru", dst: "en", correct: true,
       commands: ["ls"])

// Разбор слов
check(isWordLike("привет"), "isWordLike: слово")
check(isWordLike("дабл-шифт"), "isWordLike: с дефисом")
check(!isWordLike("com.apple"), "isWordLike: с точкой")
check(!isWordLike("-привет"), "isWordLike: дефис в начале")
check(!isWordLike("па4оль"), "isWordLike: с цифрой")
check(wordParts("дабл-шифт") == ["дабл", "шифт"], "wordParts: разбор по дефису")

// Границы слова и хвосты знаков препинания
check(trailingPunctuation("привет").tail == "", "хвост: чистое слово")
check(trailingPunctuation("привет.") == ("привет", "."), "хвост: точка")
check(trailingPunctuation("привет?!") == ("привет", "?!"), "хвост: два знака")
check(trailingPunctuation("...") == ("", "..."), "хвост: одни знаки")
check(isPureWord("привет"), "чистое слово")
check(isPureWord("дабл-шифт"), "чистое слово с дефисом")
check(!isPureWord("com.apple"), "точка — не чистое слово")
check(!isPureWord("kz@devkz"), "адрес — не чистое слово")
check(!isPureWord("па4оль"), "цифра — не чистое слово")
check(boundaryChars.contains(","), "запятая — граница слова")
check(!boundaryChars.contains("."), "точка не граница: ломала бы пути и домены")
check(identifierChars.contains("@"), "собака — часть адреса")

// Разбор сочетаний клавиш
check(parseHotkey("cmd+opt+-") == Hotkey(keycode: 27, modifiers: UInt32(cmdKey | optionKey)), "сочетание: cmd+opt+минус")
check(parseHotkey("cmd+opt+=") == Hotkey(keycode: 24, modifiers: UInt32(cmdKey | optionKey)), "сочетание: cmd+opt+равно")
check(parseHotkey("CMD + Option + 5") == Hotkey(keycode: 23, modifiers: UInt32(cmdKey | optionKey)), "сочетание: регистр и пробелы")
check(parseHotkey("ctrl+shift+f1") == Hotkey(keycode: 122, modifiers: UInt32(controlKey | shiftKey)), "сочетание: ctrl+shift+F1")
check(parseHotkey("cmd+опт+пробел") == nil, "сочетание: неизвестный модификатор отвергается")
check(parseHotkey("q") == nil, "сочетание: без модификаторов отвергается")
check(parseHotkey("cmd+щщщ") == nil, "сочетание: неизвестная клавиша отвергается")

// Правила раскладок и сочетаний по умолчанию разбираются
let rules = SnippetFile.parse(defaultLayoutRules.joined(separator: "\n"))
check(rules["com.apple.terminal"] == "en", "правила: терминал на английском")
let hotkeys = SnippetFile.parse(defaultHotkeys.joined(separator: "\n"))
check(hotkeys.count == 12, "сочетания: 12 действий по умолчанию")
check(hotkeys.allSatisfy { parseHotkey($0.value) != nil }, "сочетания: все значения разбираются")

// Словарь вставок
let parsed = SnippetFile.parse("""
# комментарий
кж = Константин Жебенев
1 = kz@devkz.ru
пустое =
= пусто
""")
check(parsed["кж"] == "Константин Жебенев", "вставки: ключ с текстом")
check(parsed["1"] == "kz@devkz.ru", "вставки: числовой слот")
check(parsed["пустое"] == nil, "вставки: пустое значение игнорируется")
check(parsed.count == 2, "вставки: только валидные строки")

// Раскладки: карта символов, если включены обе
let layouts = enabledLayouts()
if let ru = layouts.first(where: { sourceLang($0).hasPrefix("ru") }),
   let en = layouts.first(where: { sourceLang($0).hasPrefix("en") }) {
    let map = charMap(from: en, to: ru)
    check(map["f"] == "а", "карта: f -> а")
    check(map["q"] == "й", "карта: q -> й")
    let back = charMap(from: ru, to: en)
    check(back["я"] == "z", "карта: я -> z")
} else {
    print("пропуск тестов карты: нужны русская и английская раскладки")
}

print(failures == 0 ? "Все тесты пройдены: \(checks)" : "Провалено \(failures) из \(checks)")
exit(failures == 0 ? 0 : 1)
