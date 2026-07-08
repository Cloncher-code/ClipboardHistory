//  Editors.swift
//  ClipboardHistory
//
//  Редакторы: умный список и заготовка

import SwiftUI
import Combine
import AppKit
import Carbon
import ServiceManagement
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Редактор сниппета

struct SnippetEditor: View {
    @ObservedObject var manager: ClipboardManager
    @Environment(\.dismiss) private var dismiss
    @State var draft: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Заготовка").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            TextField("Название", text: $draft.title)
                .textFieldStyle(.roundedBorder)

            Text("Текст заготовки")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft.text)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))

            HStack {
                Spacer()
                Button("Сохранить") {
                    manager.saveSnippet(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440, height: 340)
    }
}

// MARK: - Редактор умного списка

struct SmartListEditor: View {
    @ObservedObject var manager: ClipboardManager
    @Environment(\.dismiss) private var dismiss
    @State var draft: SmartList

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Умный список").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            TextField("Название", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 6) {
                Text("Совпадает")
                Picker("", selection: $draft.matchAll) {
                    Text("всем").tag(true)
                    Text("любому").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Text("из условий:")
                Spacer()
            }

            ForEach($draft.rules) { $rule in
                HStack(spacing: 6) {
                    // Поле и его значение меняем одним действием, чтобы значение
                    // всегда соответствовало вариантам выбранного поля.
                    Picker("", selection: Binding(
                        get: { rule.field },
                        set: { newField in
                            $rule.field.wrappedValue = newField
                            $rule.value.wrappedValue = defaultRuleValue(for: newField)
                        }
                    )) {
                        Text("Тип").tag(SmartRule.Field.type)
                        Text("Дата").tag(SmartRule.Field.date)
                        Text("Содержит").tag(SmartRule.Field.contains)
                    }
                    .labelsHidden()
                    .fixedSize()

                    ruleValueEditor($rule)
                    Spacer()
                    Button {
                        draft.rules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                draft.rules.append(SmartRule(field: .type, value: "text"))
            } label: {
                Label("Добавить условие", systemImage: "plus")
            }

            Spacer()

            HStack {
                Spacer()
                Button("Сохранить") {
                    manager.saveSmartList(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440, height: 380)
    }

    @ViewBuilder
    private func ruleValueEditor(_ rule: Binding<SmartRule>) -> some View {
        switch rule.wrappedValue.field {
        case .type:
            Picker("", selection: rule.value) {
                Text("текст").tag("text")
                Text("ссылка").tag("link")
                Text("картинка").tag("image")
                Text("файл").tag("file")
            }
            .labelsHidden()
            .fixedSize()
        case .date:
            Picker("", selection: rule.value) {
                Text("сегодня").tag("today")
                Text("за неделю").tag("week")
            }
            .labelsHidden()
            .fixedSize()
        case .contains:
            TextField("текст", text: rule.value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
        }
    }
}
