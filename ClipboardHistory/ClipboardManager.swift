//  HistoryView.swift
//  ClipboardHistory
//
//  Главная панель истории: карточки, чипы, мультивыбор, drag&drop

import SwiftUI
import Combine
import AppKit
import Carbon
import ServiceManagement
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Стеклянная капсула (Liquid Glass на macOS 26, материал — на старых)

struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

extension View {
    // Капсула из «жидкого стекла» с безопасным откатом на материал.
    func glassCapsule() -> some View { modifier(GlassCapsule()) }
}

// Фон чипа: выбранный — акцентный цвет, невыбранный — стекло/материал.
struct ChipBackground: ViewModifier {
    let isSelected: Bool
    func body(content: Content) -> some View {
        if isSelected {
            content.background(Color.accentColor, in: Capsule())
        } else {
            content.glassCapsule()
        }
    }
}

// MARK: - Приём перетаскивания записи на чип списка

struct ChipDropModifier: ViewModifier {
    // target: nil — чип не принимает дроп; .some(nil) — убрать из списка («Все»);
    // .some(имя) — назначить в этот список.
    let target: String??
    let manager: ClipboardManager
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if let target {
            content
                .overlay(
                    Capsule().strokeBorder(Color.accentColor,
                                           lineWidth: isTargeted ? 2 : 0)
                )
                .onDrop(of: [UTType.plainText], isTargeted: $isTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                        guard let str = object as? String else { return }
                        let ids = str.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                        DispatchQueue.main.async {
                            for id in ids {
                                if let item = manager.history.first(where: { $0.id == id }) {
                                    manager.assign(item, toList: target)
                                }
                            }
                        }
                    }
                    return true
                }
        } else {
            content
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
    @State private var smartEditor: SmartList?     // редактор умного списка
    @State private var snippetEditor: Snippet?     // редактор заготовки
    @State private var showAddClip = false
    @State private var newClipText = ""
    @State private var selected = Set<UUID>()        // выделенные записи (клик / ⌘-клик)
    @State private var lastTapID: UUID?              // для ручного определения двойного клика
    @State private var lastTapTime: Date = .distantPast

    @AppStorage("autoPaste") private var autoPaste = false
    @AppStorage("compactMode") private var compactMode = false
    @AppStorage("panelSize") private var panelSize: PanelSize = .medium
    @AppStorage("panelPosition") private var panelPosition: PanelPosition = .topRight
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = cmdKey | shiftKey
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 9

    // Текущее сочетание вызова панели в читаемом виде (для подсказки).
    private var comboLabel: String {
        let mod = hotkeyModifierOptions.first { $0.flags == hotkeyModifiers }?.name ?? ""
        let key = hotkeyKeyOptions.first { $0.code == hotkeyKeyCode }?.name ?? ""
        return mod + key
    }

    private var filteredItems: [ClipboardItem] {
        var items = manager.history
        switch filter {
        case .all: items = items.filter { $0.listName == nil }   // только записи без списка
        case .list(let name): items = items.filter { $0.listName == name }
        case .smartText: items = items.filter { $0.kind == .text && !isLinkItem($0) }
        case .smartLinks: items = items.filter { isLinkItem($0) }
        case .smartImages: items = items.filter { $0.kind == .image }
        case .smartToday: items = items.filter { Calendar.current.isDateInToday($0.date) }
        case .smart(let id):
            if let sl = manager.smartLists.first(where: { $0.id == id }) {
                items = items.filter { matches($0, smart: sl) }
            } else {
                items = []
            }
        case .snippets:
            items = []   // заготовки — не история, показываются отдельным экраном
        }
        guard !searchText.isEmpty else { return items }
        return items.filter {
            $0.isSensitive != true &&
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
            .glassCapsule()
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // Чипы фильтров: один клик по нужному списку.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("Все", .all)
                    // Встроенные умные списки (быстрые пресеты).
                    chip("Текст", .smartText)
                    chip("Ссылки", .smartLinks)
                    chip("Изобр.", .smartImages)
                    chip("Сегодня", .smartToday)
                    Divider().frame(height: 16)
                    // Обычные списки, включая 📌.
                    ForEach(manager.lists, id: \.self) { name in
                        chip(name, .list(name))
                    }
                    // Пользовательские умные списки (с иконкой-воронкой).
                    ForEach(manager.smartLists) { sl in
                        chip(sl.name, .smart(sl.id), icon: "line.3.horizontal.decrease.circle")
                    }
                    // Заготовки — отдельный экран.
                    chip("Заготовки", .snippets, icon: "text.badge.star")
                    // Меню на «+»: что создать.
                    Menu {
                        Button("Обычный список") {
                            newListName = ""
                            showAddList = true
                        }
                        Button("Умный список") {
                            smartEditor = SmartList(name: "", rules: [SmartRule(field: .type, value: "text")])
                        }
                        Button("Заготовку") {
                            snippetEditor = Snippet(title: "", text: "")
                        }
                        Button("Текстовый клип") {
                            newClipText = ""
                            showAddClip = true
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .glassCapsule()
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Создать")
                }
                .padding(.horizontal, 8)
            }
            .padding(.vertical, 6)

            Divider()

            if filter == .snippets {
                snippetsList
            } else if filteredItems.isEmpty {
                Text(searchText.isEmpty
                     ? "Здесь пусто.\nСкопируйте что-нибудь (⌘C)!"
                     : "Ничего не найдено")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .frame(maxHeight: .infinity)
                    .padding(30)
            } else {
                ScrollViewReader { proxy in
                    // ScrollView вместо List: у List (таблица AppKit под капотом)
                    // своя прямоугольная подсветка строки при правом клике,
                    // которая не совпадает с нашими скруглёнными карточками.
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                rowView(item: item, index: index)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        if filteredItems.indices.contains(newIndex) {
                            proxy.scrollTo(filteredItems[newIndex].id)
                        }
                    }
                    .onChange(of: manager.openToken) { _, _ in
                        // При каждом открытии панели возвращаемся к самой свежей записи
                        // и сбрасываем мультивыбор.
                        selectedIndex = 0
                        selected.removeAll()
                        if let first = filteredItems.first {
                            DispatchQueue.main.async {
                                proxy.scrollTo(first.id, anchor: .top)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                if selected.count > 1 {
                    Button("Скопировать (\(selected.count))") { copySelected() }
                    Button("Сброс") { selected.removeAll() }
                    Spacer()
                } else {
                    Text("\(comboLabel) — открыть · ⌘клик — мультивыбор")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Menu {
                    Toggle("Пауза записи", isOn: $manager.isPaused)
                    Divider()
                    Button("Настройки…") {
                        AppDelegate.shared?.showSettingsWindow()
                    }
                    Button("Просмотр базы данных") {
                        AppDelegate.shared?.showDatabaseWindow()
                    }
                    Picker("Режим отображения", selection: $compactMode) {
                        Text("Подробный").tag(false)
                        Text("Краткий").tag(true)
                    }
                    Picker("Размер окна", selection: $panelSize) {
                        ForEach(PanelSize.allCases, id: \.self) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    Picker("Расположение", selection: $panelPosition) {
                        ForEach(PanelPosition.allCases, id: \.self) { pos in
                            Text(pos.title).tag(pos)
                        }
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
        .frame(width: panelSize.size.width,
               height: panelPosition.isDock ? manager.dockHeight : panelSize.size.height)
        // Матовое стекло вместо плоского фона — основной приём оформления macOS 26.
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: panelSize) { _, _ in AppDelegate.shared?.resizePanel() }
        .onChange(of: panelPosition) { _, _ in AppDelegate.shared?.resizePanel() }
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
        .alert("Новый текстовый клип", isPresented: $showAddClip) {
            TextField("Текст", text: $newClipText)
            Button("Добавить") { manager.addManualText(newClipText) }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(item: $smartEditor) { sl in
            SmartListEditor(manager: manager, draft: sl)
        }
        .sheet(item: $snippetEditor) { s in
            SnippetEditor(manager: manager, draft: s)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: searchText) { _, _ in selectedIndex = 0 }
        .onChange(of: filter) { _, _ in selectedIndex = 0 }
    }

    // Чип-кнопка фильтра. Подсвечивается, если выбран.
    // Чипы «Все» и обычных списков принимают перетаскивание записей.
    @ViewBuilder
    private func chip(_ title: String, _ value: HistoryFilter, icon: String? = nil) -> some View {
        let isSelected = filter == value
        let dropTarget: String?? = {                 // куда назначать при сбросе
            switch value {
            case .all:            return .some(nil)          // «Все» = убрать из списка
            case .list(let name): return .some(name)
            default:              return nil                 // умные чипы дроп не принимают
            }
        }()

        Button {
            filter = value
        } label: {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon).font(.caption2)
                }
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .modifier(ChipBackground(isSelected: isSelected))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .modifier(ChipDropModifier(target: dropTarget, manager: manager))
    }

    // Одна строка списка — оформлена как отдельная карточка.
    // Клик — выделить; ⌘-клик — добавить/убрать из выбора; двойной клик — вставить.
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

            // Бейдж распознанного типа: свотч цвета / конверт / ссылка.
            contentBadge(for: item)

            Group {
                VStack(alignment: .leading, spacing: 2) {
                    switch item.kind {
                    case .text, .file:
                        if item.isSensitive == true {
                            // Пароль: содержимое не показываем.
                            HStack(spacing: 6) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.orange)
                                Text("••••••••")
                                Text("пароль")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else if let title = item.linkTitle {
                            // Ссылка с загруженным превью: заголовок + URL мелко.
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if !compactMode {
                                    Text(item.text ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(item.text ?? "")
                                .lineLimit(compactMode ? 1 : 2)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
            // Один тап-жест: выделяет мгновенно; двойной клик определяем сами
            // по времени, чтобы не ждать таймаут двойного клика (иначе задержка).
            .onTapGesture {
                let now = Date()
                let mods = NSEvent.modifierFlags
                // Быстрый второй клик по той же записи без модификаторов — вставка.
                if lastTapID == item.id,
                   now.timeIntervalSince(lastTapTime) < 0.35,
                   !mods.contains(.command), !mods.contains(.shift) {
                    lastTapID = nil
                    activate(item)
                    return
                }
                lastTapID = item.id
                lastTapTime = now

                if mods.contains(.shift) {
                    let lo = min(selectedIndex, index)
                    let hi = max(selectedIndex, index)
                    if filteredItems.indices.contains(lo), filteredItems.indices.contains(hi) {
                        selected = Set(filteredItems[lo...hi].map { $0.id })
                    }
                } else if mods.contains(.command) {
                    toggleSelection(item)
                    selectedIndex = index
                } else {
                    selected = [item.id]
                    selectedIndex = index
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compactMode ? 6 : 9)
        // Карточка: своя подложка со скруглением + тонкая рамка.
        // Выделение: заливка у выбранных (клик/⌘-клик) и у строки под клавиатурным курсором.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((selected.contains(item.id) || index == selectedIndex)
                      ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                      : AnyShapeStyle(.thinMaterial))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    selected.contains(item.id)
                        ? Color.accentColor
                        : Color.primary.opacity(0.08),
                    lineWidth: selected.contains(item.id) ? 2 : 1
                )
        )
        // Правый клик срабатывает по всей карточке.
        .contentShape(Rectangle())
        // Перетаскивание в чип списка. Если запись входит в мультивыбор —
        // тащим все выбранные, иначе только эту.
        .onDrag {
            let ids: [UUID] = (selected.contains(item.id) && selected.count > 1)
                ? filteredItems.filter { selected.contains($0.id) }.map { $0.id }
                : [item.id]
            let payload = ids.map { $0.uuidString }.joined(separator: ",")
            return NSItemProvider(object: payload as NSString)
        }
        .contextMenu {
            Button("Вставить") { activate(item) }
            if isLinkItem(item), item.isSensitive != true,
               let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: t) {
                Button("Открыть ссылку") {
                    NSWorkspace.shared.open(url)
                    AppDelegate.shared?.closePopover()
                }
            }
            Button("Скопировать") {
                manager.copyToClipboard(item)
                AppDelegate.shared?.closePopover()
            }
            // Преобразования текста (только для текстовых записей).
            if item.kind == .text, let text = item.text {
                Menu("Скопировать как") {
                    Button("ВЕРХНИЙ РЕГИСТР") {
                        manager.copyText(text.uppercased())
                        AppDelegate.shared?.closePopover()
                    }
                    Button("нижний регистр") {
                        manager.copyText(text.lowercased())
                        AppDelegate.shared?.closePopover()
                    }
                    Button("Без лишних пробелов") {
                        let cleaned = text
                            .components(separatedBy: .whitespacesAndNewlines)
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                        manager.copyText(cleaned)
                        AppDelegate.shared?.closePopover()
                    }
                    Button("Одной строкой") {
                        let oneLine = text
                            .components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                        manager.copyText(oneLine)
                        AppDelegate.shared?.closePopover()
                    }
                }
            }
            if item.kind == .image {
                Button("Сохранить изображение…") { saveImage(item) }
            }
            Divider()
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

    // Бейдж распознанного типа контента.
    @ViewBuilder
    private func contentBadge(for item: ClipboardItem) -> some View {
        switch detectContentType(item) {
        case .color(let c):
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: c))
                .frame(width: 16, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.4)))
        case .email:
            Image(systemName: "envelope").foregroundStyle(.secondary)
        case .link:
            if let favicon = manager.loadFavicon(item) {
                Image(nsImage: favicon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .cornerRadius(3)
            } else {
                Image(systemName: "link").foregroundStyle(.secondary)
            }
        case .plain:
            EmptyView()
        }
    }

    private func toggleSelection(_ item: ClipboardItem) {
        if selected.contains(item.id) { selected.remove(item.id) }
        else { selected.insert(item.id) }
    }

    private func copySelected() {
        // Копируем в порядке отображения.
        let items = filteredItems.filter { selected.contains($0.id) }
        manager.copyCombined(items)
        selected.removeAll()
        AppDelegate.shared?.closePopover()
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

    // Вставка заготовки: кладём её текст в буфер и вставляем как обычную запись.
    private func activateSnippet(_ snippet: Snippet) {
        manager.copyText(snippet.text)
        if autoPaste && PasteHelper.hasAccessibilityPermission {
            AppDelegate.shared?.closeAndPaste()
        } else {
            AppDelegate.shared?.closePopover()
        }
    }

    // Экран текстовых заготовок.
    private var snippetsList: some View {
        Group {
            if manager.snippets.isEmpty {
                VStack(spacing: 10) {
                    Text("Заготовок пока нет")
                        .foregroundColor(.secondary)
                    Button("Создать заготовку") {
                        snippetEditor = Snippet(title: "", text: "")
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(manager.snippets) { snippet in
                            Button {
                                activateSnippet(snippet)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snippet.title.isEmpty ? "Без названия" : snippet.title)
                                        .font(.callout).bold()
                                    Text(snippet.text)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.thinMaterial))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Вставить") { activateSnippet(snippet) }
                                Button("Изменить") { snippetEditor = snippet }
                                Divider()
                                Button("Удалить", role: .destructive) { manager.deleteSnippet(snippet) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
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
            if selected.count > 1 {
                copySelected()          // мультивыбор: скопировать всё выбранное
                return true
            }
            if items.indices.contains(selectedIndex) {
                activate(items[selectedIndex])
                return true
            }
            return false
        case 53:  // Esc — сначала сбрасывает мультивыбор, затем закрывает панель
            if !selected.isEmpty {
                selected.removeAll()
                return true
            }
            AppDelegate.shared?.closePopover()
            return true
        case 51:  // ⌫ Delete — удалить выбранную запись (если не печатаем в поиске)
            if !isTyping, items.indices.contains(selectedIndex) {
                manager.delete(items[selectedIndex])
                let newCount = filteredItems.count
                selectedIndex = newCount == 0 ? 0 : min(selectedIndex, newCount - 1)
                return true
            }
            return false
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
