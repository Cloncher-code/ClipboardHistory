//  Models.swift
//  ClipboardHistory
//
//  Модели данных: записи, списки, заготовки, фильтры, распознавание контента

import SwiftUI
import Combine
import AppKit
import Carbon
import ServiceManagement
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Модель

enum ItemKind: String, Codable {
    case text
    case image
    case file
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    var id = UUID()
    let kind: ItemKind
    let text: String?            // текст записи / отображаемое имя файла
    let imageFilename: String?   // PNG на диске (картинки)
    let imageHash: String?       // отпечаток картинки (поиск дубликатов)
    let rtfFilename: String?     // RTF на диске (форматированный текст)
    let filePaths: [String]?     // пути (записи-файлы)
    let date: Date
    var listName: String?        // в каком пользовательском списке лежит запись
    var sourceBundleID: String?  // приложение, из которого скопировали (для иконки)
    var isSensitive: Bool?       // пароль/секрет: маскируется в интерфейсе (nil = обычная)
    var linkTitle: String?       // заголовок страницы (для ссылок)
    var faviconFilename: String? // файл иконки сайта в папке вложений

    static func text(_ text: String, rtfFilename: String?) -> ClipboardItem {
        ClipboardItem(kind: .text, text: text, imageFilename: nil, imageHash: nil,
                      rtfFilename: rtfFilename, filePaths: nil, date: Date())
    }
    static func image(filename: String, hash: String) -> ClipboardItem {
        ClipboardItem(kind: .image, text: nil, imageFilename: filename, imageHash: hash,
                      rtfFilename: nil, filePaths: nil, date: Date())
    }
    static func file(paths: [String]) -> ClipboardItem {
        let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return ClipboardItem(kind: .file, text: names, imageFilename: nil, imageHash: nil,
                             rtfFilename: nil, filePaths: paths, date: Date())
    }
}

// MARK: - Отметка времени записи
// Сегодня — показываем только время (Часы:Минуты).
// Другой день — показываем только дату (без времени).
enum Stamp {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
    static func label(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return timeFormatter.string(from: date)
        } else {
            return dateFormatter.string(from: date)
        }
    }
}

// MARK: - Фильтр панели (вкладки)

enum HistoryFilter: Hashable {
    case all
    case list(String)
    // Встроенные умные списки (быстрые пресеты).
    case smartText
    case smartLinks
    case smartImages
    case smartToday
    // Пользовательский умный список (по id).
    case smart(UUID)
    // Текстовые заготовки (отдельный экран, не история).
    case snippets

    var title: String {
        switch self {
        case .all: return String(localized: "Все")
        case .list(let name): return name
        case .smartText: return String(localized: "Текст")
        case .smartLinks: return String(localized: "Ссылки")
        case .smartImages: return String(localized: "Изображения")
        case .smartToday: return String(localized: "Сегодня")
        case .smart: return String(localized: "Умный список")
        case .snippets: return String(localized: "Заготовки")
        }
    }
}

// Похоже ли содержимое записи на ссылку.
func isLinkItem(_ item: ClipboardItem) -> Bool {
    guard item.kind == .text, let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
    return t.hasPrefix("http://") || t.hasPrefix("https://") || t.contains("://")
}

// MARK: - Распознавание типа контента

enum ContentType {
    case color(NSColor)
    case email
    case link
    case phone
    case plain
}

// Hex-цвет вида #RGB / #RRGGBB / #RRGGBBAA.
func hexColor(_ s: String) -> NSColor? {
    guard s.hasPrefix("#") else { return nil }
    var str = String(s.dropFirst())
    guard [3, 6, 8].contains(str.count), str.allSatisfy({ $0.isHexDigit }) else { return nil }
    if str.count == 3 { str = str.map { "\($0)\($0)" }.joined() }
    var value: UInt64 = 0
    Scanner(string: str).scanHexInt64(&value)
    let r, g, b, a: CGFloat
    if str.count == 8 {
        r = CGFloat((value >> 24) & 0xFF) / 255; g = CGFloat((value >> 16) & 0xFF) / 255
        b = CGFloat((value >> 8) & 0xFF) / 255;  a = CGFloat(value & 0xFF) / 255
    } else {
        r = CGFloat((value >> 16) & 0xFF) / 255; g = CGFloat((value >> 8) & 0xFF) / 255
        b = CGFloat(value & 0xFF) / 255;         a = 1
    }
    return NSColor(red: r, green: g, blue: b, alpha: a)
}

func isEmail(_ s: String) -> Bool {
    let pattern = "^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$"
    return s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

// Телефонный номер: +7 999 123-45-67, (495) 123-45-67 и т.п.
func isPhone(_ s: String) -> Bool {
    let pattern = "^[+]?[0-9][0-9\\s()\\-]{5,18}[0-9]$"
    guard s.range(of: pattern, options: .regularExpression) != nil else { return false }
    let digits = s.filter { $0.isNumber }.count
    return digits >= 7 && digits <= 15
}

// Цвет в виде rgb(r, g, b).
func rgbString(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB) ?? color
    return String(format: "rgb(%d, %d, %d)",
                  Int(round(c.redComponent * 255)),
                  Int(round(c.greenComponent * 255)),
                  Int(round(c.blueComponent * 255)))
}

// Цвет в виде hsl(h, s%, l%).
func hslString(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB) ?? color
    let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
    let mx = max(r, g, b), mn = min(r, g, b)
    let l = (mx + mn) / 2
    var h: CGFloat = 0, s: CGFloat = 0
    if mx != mn {
        let d = mx - mn
        s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        if mx == r      { h = (g - b) / d + (g < b ? 6 : 0) }
        else if mx == g { h = (b - r) / d + 2 }
        else            { h = (r - g) / d + 4 }
        h /= 6
    }
    return String(format: "hsl(%d, %d%%, %d%%)",
                  Int(round(h * 360)), Int(round(s * 100)), Int(round(l * 100)))
}

func detectContentType(_ item: ClipboardItem) -> ContentType {
    guard item.kind == .text, item.isSensitive != true,
          let raw = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return .plain }
    if let color = hexColor(raw) { return .color(color) }
    if isLinkItem(item) { return .link }
    if isEmail(raw) { return .email }
    if isPhone(raw) { return .phone }
    return .plain
}

// MARK: - Пользовательские умные списки (правила)

struct SmartRule: Codable, Hashable, Identifiable {
    enum Field: String, Codable, CaseIterable { case type, date, contains }
    var id = UUID()
    var field: Field
    var value: String   // type: text/link/image/file; date: today/week; contains: подстрока
}

struct SmartList: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var matchAll: Bool = true       // совпадает всем условиям / любому
    var rules: [SmartRule] = []
}

// Текстовая заготовка (сниппет) — постоянный шаблон, не вытесняется историей.
struct Snippet: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var text: String
}

// Резервная копия всех пользовательских данных.
struct BackupData: Codable {
    var history: [ClipboardItem]
    var lists: [String]
    var smartLists: [SmartList]
    var snippets: [Snippet]
    var excludedApps: [String]
}

func matches(_ item: ClipboardItem, rule: SmartRule) -> Bool {
    switch rule.field {
    case .type:
        switch rule.value {
        case "text":  return item.kind == .text && !isLinkItem(item)
        case "link":  return isLinkItem(item)
        case "image": return item.kind == .image
        case "file":  return item.kind == .file
        default:      return true
        }
    case .date:
        switch rule.value {
        case "today": return Calendar.current.isDateInToday(item.date)
        case "week":
            let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            return item.date >= weekAgo
        default: return true
        }
    case .contains:
        guard !rule.value.isEmpty else { return true }
        return (item.text ?? "").localizedCaseInsensitiveContains(rule.value)
    }
}

func matches(_ item: ClipboardItem, smart: SmartList) -> Bool {
    guard !smart.rules.isEmpty else { return true }
    let results = smart.rules.map { matches(item, rule: $0) }
    return smart.matchAll ? results.allSatisfy { $0 } : results.contains(true)
}

func defaultRuleValue(for field: SmartRule.Field) -> String {
    switch field {
    case .type: return "text"
    case .date: return "today"
    case .contains: return ""
    }
}
