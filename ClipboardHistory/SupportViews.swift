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
        case .text: return "Текст"
        case .image: return "Картинка"
        case .file: return "Файл"
        }
    }
    private func contentLabel(_ item: ClipboardItem) -> String {
        if item.isSensitive == true { return "•••••••• (пароль)" }
        return item.kind == .image ? "[изображение]" : (item.text ?? "")
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
    @State private var hasPermission = PasteHelper.hasAccessibilityPermission

    private var combo: String {
        let mod = hotkeyModifierOptions.first { $0.flags == UserDefaults.standard.integer(forKey: "hotkeyModifiers") }?.name ?? "⇧⌘"
        let key = hotkeyKeyOptions.first { $0.code == UserDefaults.standard.integer(forKey: "hotkeyKeyCode") }?.name ?? "V"
        return mod + key
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("ClipboardHistory").font(.title).bold()
            Text("Менеджер буфера обмена, который живёт в строке меню.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                onboardRow("keyboard", "Вызов панели",
                           "Нажмите \(combo) из любого приложения — откроется история буфера.")
                onboardRow("list.bullet", "Списки и заготовки",
                           "Раскладывайте записи по спискам, создавайте умные списки по правилам и постоянные текстовые заготовки.")
                onboardRow("hand.raised", "Автовставка",
                           "Чтобы запись вставлялась сразу в активное окно, нужно разрешение «Универсальный доступ».")
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))

            if hasPermission {
                Label("Разрешение выдано", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Разрешить автовставку…") { PasteHelper.requestPermission() }
            }

            Spacer()
            Button("Начать") { onDone() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            hasPermission = PasteHelper.hasAccessibilityPermission
        }
    }

    @ViewBuilder
    private func onboardRow(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
