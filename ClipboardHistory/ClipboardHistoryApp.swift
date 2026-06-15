import SwiftUI
import Combine               // ObservableObject, @Published
import AppKit
import Carbon               // глобальный хоткей
import ServiceManagement    // автозапуск
import CryptoKit            // хеши картинок

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
    var isPinned = false
    var listName: String?        // в каком пользовательском списке лежит запись
    var sourceBundleID: String?  // приложение, из которого скопировали (для иконки)

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

// MARK: - Иконки приложений-источников (с кэшем)
enum AppIcon {
    private static var cache: [String: NSImage] = [:]
    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
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

// MARK: - Менеджер буфера обмена

class ClipboardManager: ObservableObject {
    @Published var history: [ClipboardItem] = [] {
        didSet { save() }
    }
    @Published var lists: [String] = [] {
        didSet { saveLists() }
    }
    @Published var excludedApps: [String] = [] {   // bundle ID приложений-исключений
        didSet { UserDefaults.standard.set(excludedApps, forKey: "excludedApps") }
    }

    private var timer: Timer?
    private var cleanupTimer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private let storageKey = "clipboardHistory"
    private let listsKey = "userLists"

    // Настройки
    private var maxItems: Int        { UserDefaults.standard.integer(forKey: "maxItems") }
    private var savePasswords: Bool  { UserDefaults.standard.bool(forKey: "savePasswords") }
    private var playSound: Bool      { UserDefaults.standard.bool(forKey: "playSound") }
    private var soundOnCapture: Bool { UserDefaults.standard.bool(forKey: "soundOnCapture") }
    private var pastePlainText: Bool { UserDefaults.standard.bool(forKey: "pastePlainText") }
    private var cleanupDays: Int     { UserDefaults.standard.integer(forKey: "cleanupDays") }
    private var captureSoundName: String { UserDefaults.standard.string(forKey: "captureSoundName") ?? "Tink" }
    private var historySoundName: String { UserDefaults.standard.string(forKey: "historySoundName") ?? "Pop" }

    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let alwaysIgnoredTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    ]

    // Папка для вложений: ~/Library/.../Application Support/ClipboardHistory/Files
    private let attachmentsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardHistory/Files", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    init() {
        UserDefaults.standard.register(defaults: [
            "maxItems": 50,
            "savePasswords": false,
            "playSound": true,
            "soundOnCapture": false,
            "pastePlainText": false,
            "cleanupDays": 0,        // 0 = автоочистка выключена
            "autoPaste": false,
            "captureSoundName": "Tink",
            "historySoundName": "Pop",
            "compactMode": false
        ])

        load()
        loadLists()
        excludedApps = UserDefaults.standard.stringArray(forKey: "excludedApps") ?? []
        cleanupOldItems()

        // Опрос буфера каждые полсекунды (macOS не умеет уведомлять сама).
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        // Автоочистка по возрасту — раз в час.
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.cleanupOldItems()
        }
    }

    // MARK: Чтение буфера

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let types = pasteboard.types ?? []

        if types.contains(where: { alwaysIgnoredTypes.contains($0) }) { return }
        if !savePasswords && types.contains(concealedType) { return }

        // Приложение, из которого только что скопировали (для иконки записи).
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Если это приложение-исключение — ничего не записываем.
        if let source, excludedApps.contains(source) { return }

        var added = false
        if types.contains(.fileURL) {
            // Скопированы файлы (например, в Finder) — сохраняем как файлы.
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
               !urls.isEmpty {
                added = addFiles(urls, source: source)
            }
        } else if let pngData = pngData(from: pasteboard) {
            added = addImage(pngData, source: source)
        } else if let text = pasteboard.string(forType: .string) {
            // Если есть форматированная версия — сохраняем и её.
            added = addText(text, rtfData: pasteboard.data(forType: .rtf), source: source)
        }

        if added && soundOnCapture {
            Sounds.play(captureSoundName)
        }
    }

    @discardableResult
    private func addText(_ text: String, rtfData: Data?, source: String?) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        // Дубликат: сохраняем пин и список, убираем старую запись (и её RTF-файл).
        let old = history.first(where: { $0.kind == .text && $0.text == text })
        if let old { removeAttachmentFiles(old) }
        history.removeAll { $0.kind == .text && $0.text == text }

        var rtfFilename: String? = nil
        if let rtfData {
            let name = UUID().uuidString + ".rtf"
            if (try? rtfData.write(to: attachmentsDirectory.appendingPathComponent(name))) != nil {
                rtfFilename = name
            }
        }

        var item = ClipboardItem.text(text, rtfFilename: rtfFilename)
        item.isPinned = old?.isPinned ?? false
        item.listName = old?.listName
        item.sourceBundleID = source
        history.insert(item, at: 0)
        trimHistory()
        return true
    }

    @discardableResult
    private func addImage(_ pngData: Data, source: String?) -> Bool {
        let hash = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()

        let old = history.first(where: { $0.imageHash == hash })
        if let old { removeAttachmentFiles(old) }
        history.removeAll { $0.imageHash == hash }

        let filename = UUID().uuidString + ".png"
        do {
            try pngData.write(to: attachmentsDirectory.appendingPathComponent(filename))
        } catch { return false }

        var item = ClipboardItem.image(filename: filename, hash: hash)
        item.isPinned = old?.isPinned ?? false
        item.listName = old?.listName
        item.sourceBundleID = source
        history.insert(item, at: 0)
        trimHistory()
        return true
    }

    @discardableResult
    private func addFiles(_ urls: [URL], source: String?) -> Bool {
        let paths = urls.map { $0.path }

        let old = history.first(where: { $0.filePaths == paths })
        history.removeAll { $0.filePaths == paths }

        var item = ClipboardItem.file(paths: paths)
        item.isPinned = old?.isPinned ?? false
        item.listName = old?.listName
        item.sourceBundleID = source
        history.insert(item, at: 0)
        trimHistory()
        return true
    }

    private func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    // MARK: Копирование обратно в буфер

    func copyToClipboard(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            // Сначала RTF (если есть и не включён режим «без форматирования»),
            // потом обычный текст — приложения сами выберут подходящий формат.
            if !pastePlainText,
               let name = item.rtfFilename,
               let rtfData = try? Data(contentsOf: attachmentsDirectory.appendingPathComponent(name)) {
                pasteboard.setData(rtfData, forType: .rtf)
            }
            if let text = item.text {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let image = loadImage(item) {
                pasteboard.writeObjects([image])
            }
        case .file:
            if let paths = item.filePaths {
                let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
                pasteboard.writeObjects(urls)
            }
        }
        lastChangeCount = pasteboard.changeCount

        if playSound {
            Sounds.play(historySoundName)
        }
    }

    func loadImage(_ item: ClipboardItem) -> NSImage? {
        guard let filename = item.imageFilename else { return nil }
        return NSImage(contentsOf: attachmentsDirectory.appendingPathComponent(filename))
    }

    // PNG-данные картинки на диске (для «Сохранить изображение»).
    func imageData(_ item: ClipboardItem) -> Data? {
        guard let filename = item.imageFilename else { return nil }
        return try? Data(contentsOf: attachmentsDirectory.appendingPathComponent(filename))
    }

    private func removeAttachmentFiles(_ item: ClipboardItem) {
        if let name = item.imageFilename {
            try? FileManager.default.removeItem(at: attachmentsDirectory.appendingPathComponent(name))
        }
        if let name = item.rtfFilename {
            try? FileManager.default.removeItem(at: attachmentsDirectory.appendingPathComponent(name))
        }
    }

    // MARK: Управление записями

    func trimHistory() {
        var unpinnedCount = history.filter { !$0.isPinned }.count
        while unpinnedCount > maxItems {
            if let index = history.lastIndex(where: { !$0.isPinned }) {
                removeAttachmentFiles(history[index])
                history.remove(at: index)
                unpinnedCount -= 1
            } else { break }
        }
    }

    // Автоочистка: удаляем незакреплённые записи старше N дней (0 — выключено).
    func cleanupOldItems() {
        let days = cleanupDays
        guard days > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let expired = history.filter { !$0.isPinned && $0.date < cutoff }
        guard !expired.isEmpty else { return }
        expired.forEach(removeAttachmentFiles)
        history.removeAll { !$0.isPinned && $0.date < cutoff }
    }

    func togglePin(_ item: ClipboardItem) {
        if let index = history.firstIndex(where: { $0.id == item.id }) {
            history[index].isPinned.toggle()
        }
    }

    func assign(_ item: ClipboardItem, toList list: String?) {
        if let index = history.firstIndex(where: { $0.id == item.id }) {
            history[index].listName = list
        }
    }

    func delete(_ item: ClipboardItem) {
        removeAttachmentFiles(item)
        history.removeAll { $0.id == item.id }
    }

    func clearHistory() {
        history.filter { !$0.isPinned }.forEach(removeAttachmentFiles)
        history.removeAll { !$0.isPinned }
    }

    // MARK: Списки

    func addList(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !lists.contains(trimmed) else { return }
        lists.append(trimmed)
    }

    func deleteList(_ name: String) {
        lists.removeAll { $0 == name }
        // Записи из удалённого списка не пропадают, просто остаются без списка.
        for index in history.indices where history[index].listName == name {
            history[index].listName = nil
        }
    }

    // MARK: Исключения

    func addExcludedApp(_ bundleID: String) {
        guard !bundleID.isEmpty, !excludedApps.contains(bundleID) else { return }
        excludedApps.append(bundleID)
    }

    func removeExcludedApp(_ bundleID: String) {
        excludedApps.removeAll { $0 == bundleID }
    }

    // MARK: Хранение

    private func save() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ClipboardItem].self, from: data) {
            history = saved
        }
    }
    private func saveLists() {
        UserDefaults.standard.set(lists, forKey: listsKey)
    }
    private func loadLists() {
        lists = UserDefaults.standard.stringArray(forKey: listsKey) ?? []
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
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C4950), id: 1)  // 'CLIP'
        RegisterEventHotKey(UInt32(kVK_ANSI_V),
                            UInt32(cmdKey | shiftKey),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }
}

// MARK: - AppDelegate: иконка в меню-баре, поповер, хоткей

// Плавающее окно панели. Переопределяем canBecomeKey/Main,
// чтобы безрамочное окно могло принимать ввод (поиск, стрелки),
// не активируя приложение и не выкидывая из полноэкранного режима.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    let manager = ClipboardManager()
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var hotKey: HotKeyManager?
    private var previousApp: NSRunningApplication?  // кто был активен до открытия панели
    private var clickMonitor: Any?                  // следит за кликами вне панели
    private var settingsWindow: NSWindow?           // отдельное окно настроек

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                           accessibilityDescription: "История буфера")
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        // Плавающая панель вместо поповера: она умеет показываться
        // поверх полноэкранных приложений, не переключая Space.
        let hosting = NSHostingController(rootView: HistoryView(manager: manager))
        panel = FloatingPanel(contentViewController: hosting)
        panel.styleMask = [.nonactivatingPanel, .borderless]   // не активирует приложение
        panel.isFloatingPanel = true
        panel.level = .statusBar                               // поверх обычных окон
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // в т.ч. поверх fullscreen
        panel.hidesOnDeactivate = false
        // Прозрачный фон окна — само скругление и фон рисует SwiftUI-содержимое,
        // поэтому углы получаются скруглёнными, а тень повторяет их форму.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.setContentSize(NSSize(width: 340, height: 480))

        // Глобальный хоткей ⇧⌘V — работает из любого приложения.
        hotKey = HotKeyManager { [weak self] in
            self?.togglePopover()
        }
    }

    @objc func togglePopover() {
        if panel.isVisible {
            closePopover()
        } else {
            // Запоминаем активное приложение — в него потом будем вставлять.
            previousApp = NSWorkspace.shared.frontmostApplication
            positionPanel()
            // orderFrontRegardless показывает панель БЕЗ активации приложения,
            // поэтому из полноэкранного режима нас не выкидывает.
            panel.orderFrontRegardless()
            panel.makeKey()

            // Закрываем панель, когда пользователь кликает в ДРУГОМ приложении.
            // Глобальный наблюдатель не ловит клики внутри нашей панели,
            // поэтому она не закроется от кликов по своим же элементам.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    // Ставим панель под иконкой меню-бара (или по центру сверху, если иконка скрыта).
    private func positionPanel() {
        let size = panel.frame.size
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero

        var origin: NSPoint
        if let buttonWindow = statusItem.button?.window {
            let b = buttonWindow.frame
            origin = NSPoint(x: b.midX - size.width / 2, y: b.minY - size.height - 4)
        } else {
            origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.maxY - size.height - 8)
        }
        // Не вылезать за края экрана.
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        panel.setFrameOrigin(origin)
    }

    func closePopover() {
        panel.orderOut(nil)
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }

    // Закрыть панель, вернуть фокус прошлому приложению и вставить (⌘V).
    func closeAndPaste() {
        closePopover()
        previousApp?.activate(options: [.activateIgnoringOtherApps])
        // Небольшая пауза, чтобы фокус успел вернуться.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            PasteHelper.simulatePaste()
        }
    }

    // Открыть (или вынести вперёд) отдельное окно настроек с вкладками.
    func showSettingsWindow() {
        closePopover()

        // Если окно уже создано — просто показываем его снова.
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(manager: manager))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Настройки"
        window.styleMask = [.titled, .closable]   // настоящее окно: системные скруглённые углы
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Фильтр панели (вкладки)

enum HistoryFilter: Hashable {
    case all
    case pinned
    case list(String)

    var title: String {
        switch self {
        case .all: return "Все"
        case .pinned: return "Закреплённые"
        case .list(let name): return name
        }
    }
}

// MARK: - Панель истории

struct HistoryView: View {
    @ObservedObject var manager: ClipboardManager
    @State private var searchText = ""
    @State private var filter: HistoryFilter = .all
    @State private var selectedIndex = 0
    @State private var previewItem: ClipboardItem?
    @State private var keyMonitor: Any?
    @State private var showAddList = false
    @State private var newListName = ""

    @AppStorage("autoPaste") private var autoPaste = false
    @AppStorage("compactMode") private var compactMode = false

    private var filteredItems: [ClipboardItem] {
        var items = manager.history
        switch filter {
        case .all: items = items.filter { !$0.isPinned }   // закреплённые — в своём списке
        case .pinned: items = items.filter { $0.isPinned }
        case .list(let name): items = items.filter { $0.listName == name }
        }
        guard !searchText.isEmpty else { return items }
        return items.filter {
            ($0.text ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Поиск с лупой.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // Чипы фильтров: один клик по нужному списку.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("Все", .all)
                    chip("📌 Закреп", .pinned)
                    ForEach(manager.lists, id: \.self) { name in
                        chip(name, .list(name))
                    }
                    // Плюсик: добавить список не заходя в настройки.
                    Button {
                        newListName = ""
                        showAddList = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Новый список")
                }
                .padding(.horizontal, 8)
            }
            .padding(.vertical, 6)

            Divider()

            if filteredItems.isEmpty {
                Text(searchText.isEmpty
                     ? "Здесь пусто.\nСкопируйте что-нибудь (⌘C)!"
                     : "Ничего не найдено")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .frame(maxHeight: .infinity)
                    .padding(30)
            } else {
                ScrollViewReader { proxy in
                    List(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                        rowView(item: item, index: index)
                            .id(item.id)
                            .listRowBackground(Color.clear)   // строки прозрачные — видно стекло
                            .listRowSeparator(.hidden)        // свои карточки вместо линий
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)         // убираем белый фон списка
                    .onChange(of: selectedIndex) { _, newIndex in
                        if filteredItems.indices.contains(newIndex) {
                            proxy.scrollTo(filteredItems[newIndex].id)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("⇧⌘V — открыть · ↑↓ Enter · Space — превью")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Menu {
                    Button("Настройки…") {
                        AppDelegate.shared?.showSettingsWindow()
                    }
                    Picker("Режим отображения", selection: $compactMode) {
                        Text("Подробный").tag(false)
                        Text("Краткий").tag(true)
                    }
                    Divider()
                    Button("Очистить историю") { manager.clearHistory() }
                    Divider()
                    Button("Выйти") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Меню")
            }
            .padding(8)
        }
        .frame(width: 340, height: 480)
        // Матовое стекло вместо плоского фона — основной приём оформления macOS 26.
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(item: $previewItem) { item in
            PreviewView(item: item, manager: manager)
        }
        .alert("Новый список", isPresented: $showAddList) {
            TextField("Название", text: $newListName)
            Button("Добавить") {
                let name = newListName.trimmingCharacters(in: .whitespaces)
                manager.addList(name)
                if !name.isEmpty { filter = .list(name) }   // сразу переключиться на него
            }
            Button("Отмена", role: .cancel) {}
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: searchText) { _, _ in selectedIndex = 0 }
        .onChange(of: filter) { _, _ in selectedIndex = 0 }
    }

    // Чип-кнопка фильтра. Подсвечивается, если выбран.
    @ViewBuilder
    private func chip(_ title: String, _ value: HistoryFilter) -> some View {
        let isSelected = filter == value
        Button {
            filter = value
        } label: {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor)
                               : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // Одна строка списка — оформлена как отдельная карточка.
    @ViewBuilder
    private func rowView(item: ClipboardItem, index: Int) -> some View {
        HStack(spacing: 8) {
            // Иконка приложения-источника (или иконка типа записи).
            if let appIcon = AppIcon.icon(for: item.sourceBundleID) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: compactMode ? 16 : 22, height: compactMode ? 16 : 22)
            } else if item.kind == .file {
                Image(systemName: "doc")
                    .foregroundColor(.secondary)
            }

            Button {
                activate(item)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    switch item.kind {
                    case .text, .file:
                        Text(item.text ?? "")
                            .lineLimit(compactMode ? 1 : 2)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .image:
                        if let nsImage = manager.loadImage(item) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: compactMode ? 28 : 60)
                                .frame(maxWidth: .infinity, alignment: .center)  // картинка по центру
                                .cornerRadius(4)
                        } else {
                            Text("⚠️ Картинка не найдена")
                                .foregroundColor(.secondary)
                        }
                    }
                    // В кратком режиме мета-строку (дата/список/RTF) прячем.
                    if !compactMode {
                        HStack(spacing: 6) {
                            Text(Stamp.label(for: item.date))
                            if let list = item.listName {
                                Text("· \(list)")
                            }
                            if item.rtfFilename != nil {
                                Text("· RTF")
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                manager.togglePin(item)
            } label: {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .foregroundColor(item.isPinned ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(item.isPinned ? "Открепить" : "Закрепить")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compactMode ? 6 : 9)
        // Карточка: своя подложка со скруглением + тонкая рамка.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(index == selectedIndex
                      ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                      : AnyShapeStyle(.thinMaterial))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        // Правый клик срабатывает по всей карточке.
        .contentShape(Rectangle())
        .contextMenu {
            Button("Вставить") { activate(item) }
            Button("Скопировать") {
                manager.copyToClipboard(item)
                AppDelegate.shared?.closePopover()
            }
            if item.kind == .image {
                Button("Сохранить изображение…") { saveImage(item) }
            }
            Divider()
            Button(item.isPinned ? "Открепить" : "Закрепить") { manager.togglePin(item) }
            Menu("Добавить в список") {
                Button("Без списка") { manager.assign(item, toList: nil) }
                ForEach(manager.lists, id: \.self) { name in
                    Button(name) { manager.assign(item, toList: name) }
                }
            }
            Button("Предпросмотр") { previewItem = item }
            Divider()
            Button("Удалить", role: .destructive) { manager.delete(item) }
        }
    }

    // Сохранить картинку записи через системную панель сохранения.
    private func saveImage(_ item: ClipboardItem) {
        guard let data = manager.imageData(item) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "image.png"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    // Копируем запись; если включена автовставка и есть разрешение — сразу вставляем.
    private func activate(_ item: ClipboardItem) {
        manager.copyToClipboard(item)
        if autoPaste && PasteHelper.hasAccessibilityPermission {
            AppDelegate.shared?.closeAndPaste()
        } else {
            AppDelegate.shared?.closePopover()
        }
    }

    // MARK: Клавиатура: ↑↓, Enter, Esc, Space, цифры 1–9

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let items = filteredItems
        // Если пользователь печатает в поле поиска — цифры и пробел не перехватываем.
        let isTyping = NSApp.keyWindow?.firstResponder is NSTextView

        switch event.keyCode {
        case 125: // ↓
            if !items.isEmpty { selectedIndex = min(selectedIndex + 1, items.count - 1) }
            return true
        case 126: // ↑
            if !items.isEmpty { selectedIndex = max(selectedIndex - 1, 0) }
            return true
        case 36:  // Enter
            if items.indices.contains(selectedIndex) {
                activate(items[selectedIndex])
                return true
            }
            return false
        case 53:  // Esc
            AppDelegate.shared?.closePopover()
            return true
        case 49:  // Space — предпросмотр
            if !isTyping, items.indices.contains(selectedIndex) {
                previewItem = items[selectedIndex]
                return true
            }
            return false
        default:
            // Цифры 1–9 — мгновенная вставка записи с этим номером.
            if !isTyping,
               let char = event.charactersIgnoringModifiers?.first,
               let digit = char.wholeNumberValue,
               (1...9).contains(digit),
               items.indices.contains(digit - 1) {
                activate(items[digit - 1])
                return true
            }
            return false
        }
    }
}

// MARK: - Предпросмотр записи

struct PreviewView: View {
    let item: ClipboardItem
    var manager: ClipboardManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                switch item.kind {
                case .text, .file:
                    Text(item.text ?? "")
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .image:
                    if let nsImage = manager.loadImage(item) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                    }
                }
            }
            .frame(maxHeight: 360)

            HStack {
                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Скопировать") {
                    manager.copyToClipboard(item)
                    dismiss()
                }
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Настройки (отдельное окно с вкладками)

struct SettingsView: View {
    var manager: ClipboardManager

    var body: some View {
        // На macOS 26 / Xcode 26 TabView и Form сами получают оформление
        // Liquid Glass — отдельных стеклянных модификаторов тут не нужно.
        TabView {
            GeneralSettingsTab(manager: manager)
                .tabItem { Label("Основное", systemImage: "gearshape") }
            PasteSettingsTab()
                .tabItem { Label("Вставка", systemImage: "doc.on.clipboard") }
            SoundSettingsTab()
                .tabItem { Label("Звук", systemImage: "speaker.wave.2.fill") }
            ListsSettingsTab(manager: manager)
                .tabItem { Label("Списки", systemImage: "list.bullet") }
            ExclusionsSettingsTab(manager: manager)
                .tabItem { Label("Исключения", systemImage: "nosign") }
            InfoSettingsTab()
                .tabItem { Label("Информация", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 410)
    }
}

// Вкладка «Основное»: запуск, размер истории, автоочистка.
struct GeneralSettingsTab: View {
    var manager: ClipboardManager
    @AppStorage("maxItems") private var maxItems = 50
    @AppStorage("cleanupDays") private var cleanupDays = 0

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginErrorText: String?

    var body: some View {
        Form {
            Section("Запуск") {
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginErrorText = nil
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            loginErrorText = "Не удалось изменить автозапуск: \(error.localizedDescription)"
                        }
                    }
                if let loginErrorText {
                    Text(loginErrorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("История") {
                Stepper(value: $maxItems, in: 10...200, step: 10) {
                    Text("Размер истории: \(maxItems)")
                }
                .onChange(of: maxItems) { _, _ in manager.trimHistory() }

                HStack {
                    Text("Удалять записи старше")
                    TextField("0", value: $cleanupDays, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                    Text("дней")
                }
                .onChange(of: cleanupDays) { _, newValue in
                    if newValue < 0 { cleanupDays = 0 }
                    manager.cleanupOldItems()
                }
                Text("0 — не удалять автоматически. Закреплённые записи не удаляются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// Вкладка «Вставка»: автовставка и вставка без форматирования.
struct PasteSettingsTab: View {
    @AppStorage("autoPaste") private var autoPaste = false
    @AppStorage("pastePlainText") private var pastePlainText = false

    var body: some View {
        Form {
            Section {
                Toggle("Автовставка по клику / Enter", isOn: $autoPaste)
                    .onChange(of: autoPaste) { _, newValue in
                        if newValue && !PasteHelper.hasAccessibilityPermission {
                            PasteHelper.requestPermission()
                        }
                    }
                Text(PasteHelper.hasAccessibilityPermission
                     ? "Разрешение «Универсальный доступ» выдано ✓"
                     : "Нужно разрешение: Системные настройки → Конфиденциальность и безопасность → Универсальный доступ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Вставлять без форматирования", isOn: $pastePlainText)
            }
        }
        .formStyle(.grouped)
    }
}

// Вкладка «Звук».
struct SoundSettingsTab: View {
    @AppStorage("playSound") private var playSound = true
    @AppStorage("soundOnCapture") private var soundOnCapture = false
    @AppStorage("captureSoundName") private var captureSoundName = "Tink"
    @AppStorage("historySoundName") private var historySoundName = "Pop"

    var body: some View {
        Form {
            Section("При копировании из истории") {
                Toggle("Проигрывать звук", isOn: $playSound)
                Picker("Звук", selection: $historySoundName) {
                    ForEach(Sounds.all, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: historySoundName) { _, newValue in
                    Sounds.play(newValue)   // прослушать выбранный
                }
                .disabled(!playSound)
            }

            Section("При каждом копировании в системе") {
                Toggle("Проигрывать звук", isOn: $soundOnCapture)
                Picker("Звук", selection: $captureSoundName) {
                    ForEach(Sounds.all, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: captureSoundName) { _, newValue in
                    Sounds.play(newValue)
                }
                .disabled(!soundOnCapture)
                Text("Короткий сигнал каждый раз, когда что-то новое попадает в историю (любое ⌘C в любой программе).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// Вкладка «Списки».
struct ListsSettingsTab: View {
    @ObservedObject var manager: ClipboardManager
    @State private var newListName = ""

    var body: some View {
        Form {
            Section("Списки") {
                if manager.lists.isEmpty {
                    Text("Пока нет списков")
                        .foregroundStyle(.secondary)
                }
                ForEach(manager.lists, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button {
                            manager.deleteList(name)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .help("Удалить список (записи останутся)")
                    }
                }
                HStack {
                    TextField("Новый список…", text: $newListName)
                        .textFieldStyle(.roundedBorder)
                    Button("Добавить") {
                        manager.addList(newListName)
                        newListName = ""
                    }
                    .disabled(newListName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// Вкладка «Исключения»: приложения, из которых не записываем буфер, + пароли.
struct ExclusionsSettingsTab: View {
    @ObservedObject var manager: ClipboardManager
    @AppStorage("savePasswords") private var savePasswords = false

    var body: some View {
        Form {
            Section("Приложения-исключения") {
                if manager.excludedApps.isEmpty {
                    Text("Пока нет исключений")
                        .foregroundStyle(.secondary)
                }
                ForEach(manager.excludedApps, id: \.self) { bundleID in
                    HStack {
                        if let icon = AppIcon.icon(for: bundleID) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 18, height: 18)
                        }
                        Text(appName(for: bundleID))
                        Spacer()
                        Button {
                            manager.removeExcludedApp(bundleID)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .help("Убрать из исключений")
                    }
                }
                Button("Добавить приложение…") { pickApp() }
                Text("Из выбранных приложений скопированное не попадает в историю.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Пароли") {
                Toggle("Сохранять пароли в историю", isOn: $savePasswords)
                Text("Не рекомендуется: пароли будут лежать на диске в открытом виде, и их сможет прочитать любая программа или человек за этим Mac. Безопаснее оставить выключенным и хранить пароли только в менеджере паролей.")
                    .font(.caption)
                    .foregroundStyle(savePasswords ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // Понятное имя приложения по bundle ID.
    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    // Выбор .app через системную панель; берём его bundle ID.
    private func pickApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Добавить"
        if panel.runModal() == .OK,
           let url = panel.url,
           let bundleID = Bundle(url: url)?.bundleIdentifier {
            manager.addExcludedApp(bundleID)
        }
    }
}

// Вкладка «Информация»: о проекте и ссылка на GitHub.
struct InfoSettingsTab: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("ClipboardHistory")
                .font(.title2).bold()
            Text("Версия \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Менеджер буфера обмена для macOS с историей, поиском, списками и быстрой вставкой. Открытый проект.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
            Link("Открыть на GitHub",
                 destination: URL(string: "https://github.com/Cloncher-code/ClipboardHistory")!)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Точка входа

@main
struct ClipboardHistoryApp: App {
    // Вся жизнь приложения — в AppDelegate (иконка, поповер, хоткей).
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Обычных окон у приложения нет.
        Settings { EmptyView() }
    }
}
