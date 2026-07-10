//  Helpers.swift
//  ClipboardHistory
//
//  Вспомогательные утилиты: кэши, звуки, размеры/позиции панели, хоткей, чекер обновлений

import SwiftUI
import Combine
import AppKit
import Carbon
import ServiceManagement
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Иконки приложений-источников (с кэшем)
enum AppIcon {
    private static let cache = NSCache<NSString, NSImage>()
    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}

// MARK: - Кэш картинок (меньше чтений с диска при прокрутке, экономия памяти)
enum ImageCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(at url: URL, key: String) -> NSImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: key as NSString)
        return img
    }
    static func drop(_ key: String) {
        cache.removeObject(forKey: key as NSString)
    }
}

// MARK: - Звуки уведомлений
enum Sounds {
    // Системные звуки macOS (лежат в /System/Library/Sounds).
    static let all = ["Tink", "Pop", "Glass", "Ping", "Purr", "Submarine",
                      "Funk", "Morse", "Bottle", "Frog", "Blow", "Hero",
                      "Sosumi", "Basso"]
    static func play(_ name: String) {
        NSSound(named: name)?.play()
    }
}

// MARK: - Размер окна панели (пресеты)
enum PanelSize: String, CaseIterable {
    case small, medium, large

    var size: CGSize {
        switch self {
        case .small:  return CGSize(width: 300, height: 440)
        case .medium: return CGSize(width: 360, height: 520)
        case .large:  return CGSize(width: 440, height: 640)
        }
    }
    var title: String {
        switch self {
        case .small:  return String(localized: "Маленький")
        case .medium: return String(localized: "Средний")
        case .large:  return String(localized: "Большой")
        }
    }
    // Высота горизонтальной ленты (режимы «Лента снизу/сверху»).
    var stripHeight: CGFloat {
        switch self {
        case .small:  return 220
        case .medium: return 270
        case .large:  return 330
        }
    }
    // Текущий выбор из настроек (для кода вне SwiftUI).
    static var current: PanelSize {
        PanelSize(rawValue: UserDefaults.standard.string(forKey: "panelSize") ?? "medium") ?? .medium
    }
}

// MARK: - Расположение окна панели
enum PanelPosition: String, CaseIterable {
    case underIcon, topRight, topLeft, bottomRight, bottomLeft
    case dockRight, dockLeft     // док у бокового края во всю высоту
    case dockBottom, dockTop     // лента во всю ширину (как в Paste)

    var title: String {
        switch self {
        case .underIcon:   return String(localized: "Под иконкой")
        case .topRight:    return String(localized: "Справа сверху")
        case .topLeft:     return String(localized: "Слева сверху")
        case .bottomRight: return String(localized: "Справа снизу")
        case .bottomLeft:  return String(localized: "Слева снизу")
        case .dockRight:   return String(localized: "Док справа (вся высота)")
        case .dockLeft:    return String(localized: "Док слева (вся высота)")
        case .dockBottom:  return String(localized: "Лента снизу (вся ширина)")
        case .dockTop:     return String(localized: "Лента сверху (вся ширина)")
        }
    }
    var isDock: Bool { self == .dockRight || self == .dockLeft }
    var isHorizontalDock: Bool { self == .dockBottom || self == .dockTop }

    static var current: PanelPosition {
        PanelPosition(rawValue: UserDefaults.standard.string(forKey: "panelPosition") ?? "topRight") ?? .topRight
    }
}

// MARK: - Опции для настройки глобального хоткея
struct ModifierOption: Hashable { let name: String; let flags: Int }
let hotkeyModifierOptions: [ModifierOption] = [
    ModifierOption(name: "⇧⌘",  flags: cmdKey | shiftKey),
    ModifierOption(name: "⌃⌘",  flags: cmdKey | controlKey),
    ModifierOption(name: "⌥⌘",  flags: cmdKey | optionKey),
    ModifierOption(name: "⌃⌥",  flags: controlKey | optionKey),
    ModifierOption(name: "⌃⌥⌘", flags: cmdKey | controlKey | optionKey)
]
let hotkeyKeyOptions: [(name: String, code: Int)] = [
    ("V", 9), ("C", 8), ("B", 11), ("X", 7), ("Z", 6),
    ("A", 0), ("S", 1), ("D", 2), (String(localized: "Пробел"), 49)
]

// MARK: - Простой чекер обновлений через GitHub Releases
enum UpdateOutcome {
    case upToDate
    case newer(String)
    case noReleases
    case failed(String)
}

enum UpdateChecker {
    static let repo = "https://github.com/Cloncher-code/ClipboardHistory"
    // Список релизов (включает пре-релизы), а не releases/latest, который их пропускает.
    static let api = "https://api.github.com/repos/Cloncher-code/ClipboardHistory/releases?per_page=10"

    static func check() async -> UpdateOutcome {
        guard let url = URL(string: api) else { return .failed(String(localized: "Неверный адрес")) }
        var req = URLRequest(url: url)
        // GitHub API требует User-Agent и рекомендует заголовок Accept.
        req.setValue("ClipboardHistory-app", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 403 { return .failed(String(localized: "GitHub временно ограничил запросы, попробуйте позже")) }
            guard code == 200 else { return .failed(String(localized: "Код ответа \(code)")) }
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return .failed(String(localized: "Не удалось разобрать ответ"))
            }
            // Самый свежий релиз (включая пре-релизы), но не черновик.
            guard let latest = arr.first(where: { ($0["draft"] as? Bool) != true }),
                  let tag = latest["tag_name"] as? String else {
                return .noReleases
            }
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            return isNewer(tag, than: current) ? .newer(tag) : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // Сравнение версий вида "v1.2.3" / "1.2.3".
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
             .split(separator: ".")
             .map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

// MARK: - Автовставка (эмуляция ⌘V)

enum PasteHelper {
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    // Показывает системный диалог с просьбой выдать разрешение Accessibility.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9  // клавиша V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

// MARK: - Глобальный хоткей (⇧⌘V) через Carbon

class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.handler() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        register()
    }

    // Регистрируем хоткей по текущим настройкам (можно вызывать повторно).
    func register() {
        unregister()
        let keyCode = UInt32(UserDefaults.standard.integer(forKey: "hotkeyKeyCode"))
        let mods = UInt32(UserDefaults.standard.integer(forKey: "hotkeyModifiers"))
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C4950), id: 1)  // 'CLIP'
        RegisterEventHotKey(keyCode, mods, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
