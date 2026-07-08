//  ClipboardHistoryApp.swift
//  ClipboardHistory
//
//  Точка входа приложения

import SwiftUI
import Combine
import AppKit
import Carbon
import ServiceManagement
import CryptoKit
import UniformTypeIdentifiers

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
