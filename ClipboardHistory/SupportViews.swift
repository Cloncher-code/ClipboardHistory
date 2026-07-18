//  SupportViews.swift
//  ClipboardHistory
//
//  Вспомогательные экраны: предпросмотр, база данных, онбординг

import SwiftUI
import Combine
import AppKit
import Carbon
import ServiceManagement
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Просмотр базы данных

struct DatabaseView: View {
    @ObservedObject var manager: ClipboardManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Всего записей: \(manager.history.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
            Divider()
            Table(manager.history) {
                TableColumn("Тип") { item in Text(typeLabel(item)) }
                    .width(70)
                TableColumn("Содержимое") { item in
                    Text(contentLabel(item)).lineLimit(1)
                }
                TableColumn("Дата") { item in
                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                }
                .width(150)
                TableColumn("Список") { item in Text(item.listName ?? "—") }
                    .width(90)
                TableColumn("Источник") { item in Text(sourceLabel(item)) }
                    .width(130)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private func typeLabel(_ item: ClipboardItem) -> String {
        switch item.kind {
        case .text: return String(localized: "Текст")
        case .image: return String(localized: "Картинка")
        case .file: return String(localized: "Файл")
        }
    }
    private func contentLabel(_ item: ClipboardItem) -> String {
        if item.isSensitive == true { return String(localized: "•••••••• (пароль)") }
        return item.kind == .image ? String(localized: "[изображение]") : (item.text ?? "")
    }
    private func sourceLabel(_ item: ClipboardItem) -> String {
        guard let id = item.sourceBundleID else { return "—" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return url.deletingPathExtension().lastPathComponent
        }
        return id
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

// MARK: - Онбординг (первый запуск)

struct OnboardingView: View {
    let onDone: () -> Void
    @State private var step = 0
    @State private var hasPermission = PasteHelper.hasAccessibilityPermission
    private let totalSteps = 4

    private var combo: String {
        let mod = hotkeyModifierOptions.first { $0.flags == UserDefaults.standard.integer(forKey: "hotkeyModifiers") }?.name ?? "⇧⌘"
        let key = hotkeyKeyOptions.first { $0.code == UserDefaults.standard.integer(forKey: "hotkeyKeyCode") }?.name ?? "V"
        return mod + key
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 8)

            // Содержимое текущего шага.
            Group {
                switch step {
                case 0: welcomeStep
                case 1: panelStep
                case 2: organizeStep
                default: pasteStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Точки-индикаторы шагов.
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            // Навигация.
            HStack {
                if step > 0 {
                    Button("Назад") { withAnimation { step -= 1 } }
                }
                Spacer()
                if step < totalSteps - 1 {
                    Button("Далее") { withAnimation { step += 1 } }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Начать") { onDone() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            hasPermission = PasteHelper.hasAccessibilityPermission
        }
    }

    // Шаг 1: приветствие.
    private var welcomeStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("ClipboardHistory").font(.largeTitle).bold()
            Text("Менеджер буфера обмена, который живёт в строке меню.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // Шаг 2: вызов панели.
    private var panelStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "keyboard")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Вызов панели").font(.title2).bold()
            KeyCap(text: combo)
                .scaleEffect(1.4)
                .padding(.vertical, 6)
            Text("Нажмите \(combo) из любого приложения — откроется история буфера.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Сочетание можно поменять в настройках, вкладка «Клавиши».")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // Шаг 3: организация.
    private var organizeStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Списки и заготовки").font(.title2).bold()
            Text("Раскладывайте записи по спискам, создавайте умные списки по правилам и постоянные текстовые заготовки.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Перетаскивайте записи на чипы списков, ⌘клик — мультивыбор, правый клик — все действия.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // Шаг 4: автовставка и разрешение.
    private var pasteStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.raised")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Автовставка").font(.title2).bold()
            Text("Чтобы запись вставлялась сразу в активное окно, нужно разрешение «Универсальный доступ».")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if hasPermission {
                Label("Разрешение выдано", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Разрешить автовставку…") { PasteHelper.requestPermission() }
                    .buttonStyle(.borderedProminent)
            }
            Text("Этот шаг можно пропустить и вернуться позже: Настройки → Вставка.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
