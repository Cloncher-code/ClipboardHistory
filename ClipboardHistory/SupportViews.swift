//  SettingsViews.swift
//  ClipboardHistory
//
//  Окно настроек и все его вкладки

import SwiftUI
import Combine
import AppKit
import Carbon
import ServiceManagement
import CryptoKit
import UniformTypeIdentifiers

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
            ShortcutsSettingsTab()
                .tabItem { Label("Клавиши", systemImage: "keyboard") }
            ListsSettingsTab(manager: manager)
                .tabItem { Label("Списки", systemImage: "list.bullet") }
            ExclusionsSettingsTab(manager: manager)
                .tabItem { Label("Исключения", systemImage: "nosign") }
            InfoSettingsTab()
                .tabItem { Label("Информация", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 420)
    }
}

// Вкладка «Основное»: запуск, размер истории, автоочистка.
struct GeneralSettingsTab: View {
    var manager: ClipboardManager
    @AppStorage("maxItems") private var maxItems = 50
    @AppStorage("cleanupDays") private var cleanupDays = 0

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginErrorText: String?
    @State private var backupMessage: String?
    @AppStorage("linkPreviews") private var linkPreviews = true

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
                Text("0 — не удалять автоматически. Записи, добавленные в списки, не удаляются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ссылки") {
                Toggle("Загружать превью ссылок", isOn: $linkPreviews)
                Text("Для скопированных ссылок подтягиваются заголовок страницы и иконка сайта. Приложение обращается к сайту по адресу ссылки.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Резервная копия") {
                HStack {
                    Button("Экспорт…") { exportBackup() }
                    Button("Импорт…") { importBackup() }
                }
                if let backupMessage {
                    Text(backupMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Сохраняет историю, списки, умные списки и заготовки в файл. Пароли и картинки-вложения в файл не входят.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func exportBackup() {
        guard let data = manager.exportBackup() else {
            backupMessage = "Не удалось подготовить данные"; return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ClipboardHistory-backup.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                backupMessage = "Экспортировано"
            } catch {
                backupMessage = "Ошибка записи: \(error.localizedDescription)"
            }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if let data = try? Data(contentsOf: url), manager.importBackup(data) {
                backupMessage = "Импортировано"
            } else {
                backupMessage = "Не удалось прочитать файл резервной копии"
            }
        }
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
    @State private var smartEditor: SmartList?
    @State private var snippetEditor: Snippet?
    @State private var renameTarget: String?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Списки — перетащите за ☰, чтобы изменить порядок")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 4)

            List {
                Section("Обычные списки") {
                    if manager.lists.isEmpty {
                        Text("Пока нет списков").foregroundStyle(.secondary)
                    }
                    ForEach(manager.lists, id: \.self) { name in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                            Text(name)
                            Spacer()
                            if name != "📌" {   // системный список не переименовываем
                                Button {
                                    renameText = name
                                    renameTarget = name
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.plain)
                                .help("Переименовать")
                            }
                            Button {
                                manager.deleteList(name)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Удалить список (записи останутся)")
                        }
                    }
                    .onMove(perform: manager.moveList)
                }

                Section("Умные списки") {
                    if manager.smartLists.isEmpty {
                        Text("Пока нет умных списков").foregroundStyle(.secondary)
                    }
                    ForEach(manager.smartLists) { sl in
                        HStack {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundStyle(.tertiary)
                            Text(sl.name)
                            Spacer()
                            Button { smartEditor = sl } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .help("Изменить")
                            Button { manager.deleteSmartList(sl) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Удалить умный список")
                        }
                    }
                    Button {
                        smartEditor = SmartList(name: "", rules: [SmartRule(field: .type, value: "text")])
                    } label: {
                        Label("Создать умный список", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                }

                Section("Заготовки") {
                    if manager.snippets.isEmpty {
                        Text("Пока нет заготовок").foregroundStyle(.secondary)
                    }
                    ForEach(manager.snippets) { snippet in
                        HStack {
                            Image(systemName: "text.badge.star")
                                .foregroundStyle(.tertiary)
                            Text(snippet.title.isEmpty ? "Без названия" : snippet.title)
                            Spacer()
                            Button { snippetEditor = snippet } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .help("Изменить")
                            Button { manager.deleteSnippet(snippet) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Удалить заготовку")
                        }
                    }
                    Button {
                        snippetEditor = Snippet(title: "", text: "")
                    } label: {
                        Label("Создать заготовку", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField("Новый список…", text: $newListName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addAndClear() }
                Button("Добавить") { addAndClear() }
                    .disabled(newListName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .sheet(item: $smartEditor) { sl in
            SmartListEditor(manager: manager, draft: sl)
        }
        .sheet(item: $snippetEditor) { s in
            SnippetEditor(manager: manager, draft: s)
        }
        .alert("Переименовать список", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Название", text: $renameText)
            Button("Сохранить") {
                if let old = renameTarget {
                    manager.renameList(old, to: renameText)
                }
                renameTarget = nil
            }
            Button("Отмена", role: .cancel) { renameTarget = nil }
        }
    }

    private func addAndClear() {
        manager.addList(newListName)
        newListName = ""
    }
}

// Капсула с обозначением клавиши.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

// Вкладка «Сочетания клавиш»: настройка вызова панели + справка.
struct ShortcutsSettingsTab: View {
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = cmdKey | shiftKey
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 9

    private var currentCombo: String {
        let mod = hotkeyModifierOptions.first { $0.flags == hotkeyModifiers }?.name ?? ""
        let key = hotkeyKeyOptions.first { $0.code == hotkeyKeyCode }?.name ?? ""
        return mod + key
    }

    private let panelRows: [(String, [String])] = [
        ("Перемещение по списку", ["↑", "↓"]),
        ("Вставить выбранную запись", ["↵"]),
        ("Быстрая вставка", ["1", "…", "9"]),
        ("Предпросмотр записи", ["Space"]),
        ("Удалить запись", ["⌫"]),
        ("Закрыть панель", ["esc"])
    ]

    var body: some View {
        Form {
            Section {
                Text("Настройте вызов панели и посмотрите сочетания внутри неё.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Вызов панели") {
                HStack {
                    Text("Активировать панель")
                    Spacer()
                    KeyCap(text: currentCombo)
                }
                Picker("Модификаторы", selection: $hotkeyModifiers) {
                    ForEach(hotkeyModifierOptions, id: \.flags) { Text($0.name).tag($0.flags) }
                }
                .onChange(of: hotkeyModifiers) { _, _ in AppDelegate.shared?.reregisterHotKey() }
                Picker("Клавиша", selection: $hotkeyKeyCode) {
                    ForEach(hotkeyKeyOptions, id: \.code) { Text($0.name).tag($0.code) }
                }
                .onChange(of: hotkeyKeyCode) { _, _ in AppDelegate.shared?.reregisterHotKey() }
            }

            Section("Внутри панели") {
                ForEach(panelRows, id: \.0) { row in
                    HStack {
                        Text(row.0)
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(row.1, id: \.self) { KeyCap(text: $0) }
                        }
                    }
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
    @AppStorage("hidePasswordLike") private var hidePasswordLike = false

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
                Toggle("Пропускать текст, похожий на пароль", isOn: $hidePasswordLike)
                    .disabled(savePasswords)
                Text("Дополнительная защита: строки без пробелов из букв, цифр и символов (8–64 знака) не попадут в историю, даже если приложение не пометило их как пароль. Может изредка пропускать похожие коды и ключи.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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


struct InfoSettingsTab: View {
    @State private var updateStatus: String?
    @State private var updateAvailable = false
    @State private var checking = false

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

            // Проверка обновлений через GitHub Releases.
            Button {
                Task {
                    checking = true
                    updateStatus = nil
                    updateAvailable = false
                    switch await UpdateChecker.check() {
                    case .newer(let tag):
                        updateStatus = "Доступна новая версия: \(tag)"
                        updateAvailable = true
                    case .upToDate:
                        updateStatus = "У вас последняя версия"
                    case .noReleases:
                        updateStatus = "На GitHub пока нет опубликованных релизов"
                    case .failed(let why):
                        updateStatus = "Не удалось проверить: \(why)"
                    }
                    checking = false
                }
            } label: {
                if checking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Проверить обновления")
                }
            }
            .disabled(checking)

            if let updateStatus {
                Text(updateStatus)
                    .font(.caption)
                    .foregroundStyle(updateAvailable ? .orange : .secondary)
            }

            HStack(spacing: 10) {
                Link("Открыть на GitHub",
                     destination: URL(string: UpdateChecker.repo)!)
                    .buttonStyle(.borderedProminent)
                if updateAvailable {
                    Link("Скачать обновление",
                         destination: URL(string: UpdateChecker.repo + "/releases")!)
                }
            }
            Button("Показать приветствие снова") {
                AppDelegate.shared?.showOnboardingWindow()
            }
            .buttonStyle(.link)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
