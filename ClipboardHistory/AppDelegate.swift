//  AppDelegate.swift
//  ClipboardHistory
//
//  Жизненный цикл: иконка меню-бара, плавающая панель, окна

import SwiftUI
import Combine
import AppKit
import Carbon
import ServiceManagement
import CryptoKit
import UniformTypeIdentifiers
#if canImport(Sparkle)
import Sparkle   // автообновления; подключается через Swift Package Manager
#endif

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
    private var databaseWindow: NSWindow?           // окно просмотра базы
    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Sparkle: тихая проверка обновлений по расписанию + UI обновления.
        #if canImport(Sparkle)
        updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                         updaterDelegate: nil,
                                                         userDriverDelegate: nil)
        #endif

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                           accessibilityDescription: String(localized: "История буфера"))
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        // Реагируем и на левый, и на правый клик (правый — контекстное меню).
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

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
        panel.setContentSize(PanelSize.current.size)

        // Глобальный хоткей ⇧⌘V — работает из любого приложения.
        hotKey = HotKeyManager { [weak self] in
            self?.togglePopover()
        }

        // Первый запуск — показываем приветствие один раз.
        if !UserDefaults.standard.bool(forKey: "onboardingShown") {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboardingWindow()
            }
        }
    }

    private var onboardingWindow: NSWindow?

    func showOnboardingWindow() {
        if let onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            onboardingWindow.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView {
            UserDefaults.standard.set(true, forKey: "onboardingShown")
            self.onboardingWindow?.close()
        })
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Добро пожаловать")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 520))
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func togglePopover() {
        // Правый клик по иконке — контекстное меню вместо панели.
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showStatusMenu()
            return
        }
        if panel.isVisible {
            closePopover()
        } else {
            // Запоминаем активное приложение — в него потом будем вставлять.
            previousApp = NSWorkspace.shared.frontmostApplication
            manager.openToken += 1   // сигнал панели прокрутиться вверх
            applyPanelLayout()       // размер и позиция (учитывает режим дока)
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

    // Ставим панель по выбранному расположению на экране с курсором.
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // Единый пересчёт размера и позиции панели (учитывает режим дока).
    func applyPanelLayout() {
        let screen = targetScreen()
        let visible = screen?.visibleFrame ?? .zero
        let margin: CGFloat = 8
        let pos = PanelPosition.current
        let width = PanelSize.current.size.width

        let size: NSSize
        if pos.isDock {
            size = NSSize(width: width, height: visible.height - margin * 2)  // вся высота
        } else if pos.isHorizontalDock {
            size = NSSize(width: visible.width - margin * 2,                  // вся ширина
                          height: PanelSize.current.stripHeight)
        } else {
            size = PanelSize.current.size
        }
        panel.setContentSize(size)
        manager.dockHeight = size.height   // чтобы SwiftUI-контент совпал по высоте
        manager.dockWidth = size.width     // ...и по ширине (для ленты)
        positionPanel(on: screen)
    }

    private func positionPanel(on screen: NSScreen?) {
        let size = panel.frame.size
        let margin: CGFloat = 8
        let visible = screen?.visibleFrame ?? .zero

        var origin: NSPoint
        switch PanelPosition.current {
        case .underIcon:
            // Под иконкой — только если её окно на том же экране, что и курсор.
            if let buttonWindow = statusItem.button?.window,
               let screen,
               screen.frame.contains(NSPoint(x: buttonWindow.frame.midX,
                                             y: buttonWindow.frame.midY)) {
                let b = buttonWindow.frame
                origin = NSPoint(x: b.midX - size.width / 2, y: b.minY - size.height - 4)
            } else {
                origin = NSPoint(x: visible.midX - size.width / 2,
                                 y: visible.maxY - size.height - margin)
            }
        case .topRight:
            origin = NSPoint(x: visible.maxX - size.width - margin,
                             y: visible.maxY - size.height - margin)
        case .topLeft:
            origin = NSPoint(x: visible.minX + margin,
                             y: visible.maxY - size.height - margin)
        case .bottomRight:
            origin = NSPoint(x: visible.maxX - size.width - margin,
                             y: visible.minY + margin)
        case .bottomLeft:
            origin = NSPoint(x: visible.minX + margin,
                             y: visible.minY + margin)
        case .dockRight:
            origin = NSPoint(x: visible.maxX - size.width - margin,
                             y: visible.minY + margin)
        case .dockLeft:
            origin = NSPoint(x: visible.minX + margin,
                             y: visible.minY + margin)
        case .dockBottom:
            origin = NSPoint(x: visible.minX + margin,
                             y: visible.minY + margin)
        case .dockTop:
            origin = NSPoint(x: visible.minX + margin,
                             y: visible.maxY - size.height - margin)
        }
        // Не вылезать за края выбранного экрана.
        origin.x = max(visible.minX + margin, min(origin.x, visible.maxX - size.width - margin))
        origin.y = max(visible.minY + margin, min(origin.y, visible.maxY - size.height - margin))
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

    // Видна ли сейчас панель (для гарда клавиатурного монитора).
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    // Перепривязать глобальный хоткей после изменения в настройках.
    func reregisterHotKey() {
        hotKey?.register()
    }

    // MARK: Контекстное меню иконки статус-бара (правый клик)

    private func showStatusMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: String(localized: "Открыть панель"),
                              action: #selector(menuOpenPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let pause = NSMenuItem(title: String(localized: "Пауза записи"),
                               action: #selector(menuTogglePause), keyEquivalent: "")
        pause.target = self
        pause.state = manager.isPaused ? .on : .off
        menu.addItem(pause)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: String(localized: "Настройки…"),
                                  action: #selector(menuOpenSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let updates = NSMenuItem(title: String(localized: "Проверить обновления…"),
                                 action: #selector(menuCheckUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: String(localized: "Выйти"),
                              action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Трюк: временно назначаем меню и «кликаем» — оно откроется у иконки.
        // Затем убираем, чтобы левый клик продолжил открывать панель.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenPanel()   { togglePopover() }
    @objc private func menuTogglePause() { manager.isPaused.toggle() }
    @objc private func menuOpenSettings(){ showSettingsWindow() }
    @objc private func menuCheckUpdates(){ checkForUpdates() }
    @objc private func menuQuit()        { NSApplication.shared.terminate(nil) }

    // Проверить обновления: через Sparkle, если подключён;
    // иначе открываем настройки с ручным чекером на вкладке «Информация».
    func checkForUpdates() {
        #if canImport(Sparkle)
        closePopover()
        updaterController?.checkForUpdates(nil)
        #else
        showSettingsWindow()
        #endif
    }

    // Иконка в меню-баре: обычная или «пауза».
    func updateStatusIcon() {
        let name = manager.isPaused ? "pause.circle" : "doc.on.clipboard"
        statusItem.button?.image = NSImage(systemSymbolName: name,
                                           accessibilityDescription: String(localized: "История буфера"))
    }

    // Сменить размер/позицию панели на лету (из настроек/меню).
    func resizePanel() {
        applyPanelLayout()
    }

    // Гарантированно сохраняем историю при выходе (на случай отложенной записи).
    func applicationWillTerminate(_ notification: Notification) {
        manager.flush()
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
        window.title = String(localized: "Настройки")
        window.styleMask = [.titled, .closable]   // настоящее окно: системные скруглённые углы
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // Открыть окно «Просмотр базы данных» — таблица всех записей.
    func showDatabaseWindow() {
        closePopover()
        if let databaseWindow {
            NSApp.activate(ignoringOtherApps: true)
            databaseWindow.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: DatabaseView(manager: manager))
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "База данных")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 460))
        window.center()
        databaseWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
