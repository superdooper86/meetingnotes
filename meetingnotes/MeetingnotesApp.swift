//
//  meetingnotesApp.swift
//  meetingnotes
//
//  Created by Owen Gretzinger on 2025-07-10.
//

import SwiftUI
import AppKit
import Sparkle
import PostHog

@main
struct MeetingnotesApp: App {
    private let updaterController: SPUStandardUpdaterController
    @StateObject private var recordingSessionManager = RecordingSessionManager.shared

    init() {
        updaterController = SPUStandardUpdaterController(updaterDelegate: nil, userDriverDelegate: nil)
        // Setup PostHog analytics for anonymous tracking
        let posthogAPIKey = "phc_Wt8sWUzUF7YPF50aQ0B1qbfA5SJWWR341zmXCaIaIRJ"
        let posthogHost = "https://us.i.posthog.com"
        let config = PostHogConfig(apiKey: posthogAPIKey, host: posthogHost)
        // Only capture anonymous events
        config.personProfiles = .never
        // Enable lifecycle and screen view autocapture
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = true
        PostHogSDK.shared.setup(config)
        // Register environment as a super property
        #if DEBUG
        PostHogSDK.shared.register(["environment": "dev"] )
        #else
        PostHogSDK.shared.register(["environment": "prod"] )
        #endif
    }

    var body: some Scene {
        WindowGroup("Meetingnotes", id: "main") {
            ContentView()
                .frame(minWidth: 700, minHeight: 400)
                .background(MainWindowConfigurator())
        }
        .windowResizability(.automatic)
        .defaultSize(width: 1000, height: 600)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        MenuBarExtra {
            MeetingnotesMenu(
                recordingSessionManager: recordingSessionManager,
                updater: updaterController.updater
            )
        } label: {
            Image(systemName: recordingSessionManager.isRecording ? "record.circle.fill" : "waveform")
                .accessibilityLabel(recordingSessionManager.isRecording ? "Meetingnotes recording" : "Meetingnotes")
        }
    }
}

private struct MeetingnotesMenu: View {
    @ObservedObject var recordingSessionManager: RecordingSessionManager
    let updater: SPUUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if recordingSessionManager.isRecording {
            Label("Recording", systemImage: "record.circle.fill")
        } else if recordingSessionManager.isProcessing {
            Label("Processing audio", systemImage: "hourglass")
        }

        Button {
            MainWindowController.shared.show(using: openWindow)
        } label: {
            Label("Open Meetingnotes", systemImage: "macwindow")
        }

        Divider()

        Button {
            updater.checkForUpdates()
        } label: {
            Label("Check for Updates...", systemImage: "arrow.triangle.2.circlepath")
        }
        .keyboardShortcut("u")

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit Meetingnotes", systemImage: "power")
        }
        .keyboardShortcut("q")
    }
}

@MainActor
private final class MainWindowController: NSObject {
    static let shared = MainWindowController()

    private weak var window: NSWindow?

    func configure(_ window: NSWindow) {
        if self.window !== window {
            if let previousWindow = self.window {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.willMiniaturizeNotification,
                    object: previousWindow
                )
            }
            self.window = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillMiniaturize(_:)),
                name: NSWindow.willMiniaturizeNotification,
                object: window
            )
        }

        if let minimizeButton = window.standardWindowButton(.miniaturizeButton) {
            minimizeButton.target = self
            minimizeButton.action = #selector(hideWindow(_:))
        }
    }

    func show(using openWindow: OpenWindowAction) {
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func hideWindow(_ sender: NSButton) {
        sender.window?.orderOut(nil)
    }

    @objc private func windowWillMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async {
            window.deminiaturize(nil)
            window.orderOut(nil)
        }
    }
}

private struct MainWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            MainWindowController.shared.configure(window)
        }
    }
}

struct CheckForUpdatesView: View {
    let updater: SPUUpdater

    var body: some View {
        Button("Check for Updates...") {
            updater.checkForUpdates()
        }
        .keyboardShortcut("u", modifiers: .command)
    }
}
