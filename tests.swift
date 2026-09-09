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
let expectedActions = Set(["строка", "абзац", "ключ", "буфер"]
    + (1...9).map { "слот-\($0)" } + (1...10).map { "пресет-\($0)" })
check(Set(hotkeys.keys) == expectedActions, "сочетания: все действия описаны по умолчанию")
check(Set(SnippetFile.parse(defaultPresets.joined(separator: "\n")).keys).contains("1"),
      "пресеты: первый задан по умолчанию")
check(hotkeys.allSatisfy { parseHotkey($0.value) != nil }, "сочетания: все значения разбираются")

// Адреса и номера версий, набранные не в той раскладке
expect(typed: "192ю168ю2ю1", converted: "192.168.2.1", src: "ru", dst: "en", correct: true)
expect(typed: "192ю168ю2ю47:5000", converted: "192.168.2.47:5000", src: "ru", dst: "en", correct: true)
expect(typed: "1ю2ю3", converted: "1.2.3", src: "ru", dst: "en", correct: true)
expect(typed: "192.168.2.1", converted: "192ю168ю2ю1", src: "en", dst: "ru", correct: false)
check(looksLikeDottedNumber("192.168.2.1"), "адрес: обычный IPv4")
check(looksLikeDottedNumber("10.0.0.1:8080"), "адрес: с портом")
check(!looksLikeDottedNumber("192.168"), "адрес: двух групп мало")
check(!looksLikeDottedNumber("привет.как.дела"), "адрес: буквы не считаются")
check(!looksLikeDottedNumber("1.2.3.4567"), "адрес: группа длиннее трёх цифр")

// Ссылки, почта и национальные домены
check(looksTechnical("http://vk.com"), "ссылка со схемой")
check(looksTechnical("www.google.com"), "ссылка с www")
check(looksTechnical("kz@devkz.ru"), "адрес почты")
check(looksTechnical("/usr/local/bin"), "путь")
check(looksTechnical("localhost:8080/api"), "хост с портом")
check(!looksTechnical("привет"), "обычное слово")
check(!looksTechnical("дабл-шифт"), "слово с дефисом")
check(isNationalDomain("ujceckeub.ha"), "домен .рф, набранный не в той раскладке")
check(isNationalDomain("госуслуги.рф"), "домен .рф кириллицей")
check(!isNationalDomain("vk.com"), "обычный домен")

// Конвертация текста уважает ссылки и адреса
if let ru = enabledLayouts().first(where: { sourceLang($0).hasPrefix("ru") }),
   let en = enabledLayouts().first(where: { sourceLang($0).hasPrefix("en") }) {
    let toRu = charMap(from: en, to: ru)
    check(convertTextTokens("ghbdtn", map: toRu) == "привет", "текст: обычное слово конвертируется")
    check(convertTextTokens("http://vk.com", map: toRu) == "http://vk.com", "текст: ссылка не тронута")
    check(convertTextTokens("kz@devkz.ru", map: toRu) == "kz@devkz.ru", "текст: почта не тронута")
    check(convertTextTokens("ghbdtn http://vk.com", map: toRu) == "привет http://vk.com",
          "текст: слово рядом со ссылкой конвертируется")
    let national = convertTextTokens("https://ujceckeub.ha", map: toRu)
    check(national.hasPrefix("https://") && national.hasSuffix(".рф"),
          "текст: домен .рф чинится, схема остаётся латиницей (получено «\(national)»)")
}

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

// Клавиши, которые в одной раскладке знак, а в другой буква
expect(typed: "ghjljk;fq", converted: "продолжай", src: "en", dst: "ru", correct: true)
expect(typed: "ke;f", converted: "лужа", src: "en", dst: "ru", correct: true)
expect(typed: "ht,znf", converted: "ребята", src: "en", dst: "ru", correct: true)
expect(typed: "'nj", converted: "это", src: "en", dst: "ru", correct: true)

// Раскладки: карта символов, если включены обе
let layouts = enabledLayouts()
if let ru = layouts.first(where: { sourceLang($0).hasPrefix("ru") }),
   let en = layouts.first(where: { sourceLang($0).hasPrefix("en") }) {
    let map = charMap(from: en, to: ru)
    check(map["f"] == "а", "карта: f -> а")
    check(map["q"] == "й", "карта: q -> й")
    let back = charMap(from: ru, to: en)
    check(back["я"] == "z", "карта: я -> z")

    // «;» и «,» — буквы в русской раскладке, значит не могут быть концом слова
    let semicolon = Stroke(keycode: 41, shift: false, caps: false)
    let comma = Stroke(keycode: 43, shift: false, caps: false)
    let exclamation = Stroke(keycode: 18, shift: true, caps: false)
    check(translate([semicolon], via: ru) == "ж", "клавиша «;» в русской даёт «ж»")
    check(!punctuationInBothLayouts(semicolon, en, ru), "«;» не конец слова: в русской это буква")
    check(!punctuationInBothLayouts(comma, en, ru), "«,» не конец слова: в русской это буква")
    check(punctuationInBothLayouts(exclamation, en, ru), "«!» конец слова в обеих раскладках")
} else {
    print("пропуск тестов карты: нужны русская и английская раскладки")
}

print(failures == 0 ? "Все тесты пройдены: \(checks)" : "Провалено \(failures) из \(checks)")
exit(failures == 0 ? 0 : 1)
