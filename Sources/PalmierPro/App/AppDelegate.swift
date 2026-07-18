import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate the app (required when launched from CLI, not a .app bundle)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        InstallLocation.offerMoveIfLaunchedFromDMG()

        // Start Sparkle updater
        _ = Updater.shared

        // Restore the Supabase session (no gate — sign-in only unlocks the LLM proxy).
        AuthCoordinator.start()

        if UserProfileStore.shared.isOnboarded {
            HomeWindowController.shared.showWindow(nil)
        } else {
            OnboardingWindowController.shared.showWindow(nil)
        }

        // Warn when connectivity drops; AI/online features require internet.
        NetworkMonitor.shared.start()
        Task.detached(priority: .utility) {
            Project.ensureStorageDirectory()
        }

        AppNotifications.configure()

        AppState.shared.startMCPService()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.shared.showHome()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "kawenreel" {
            Task { @MainActor in
                do {
                    try await SupabaseService.shared.handleAuthCallback(url)
                    Log.account.notice("auth callback handled", telemetry: "Auth callback handled")
                } catch {
                    Log.account.warning(
                        "auth callback failed: \(Log.detail(error))",
                        telemetry: "Auth callback failed",
                        data: ["error": error.localizedDescription]
                    )
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        isTerminating = true
        let projects = AppState.shared.openProjects

        Task { @MainActor in
            do {
                for project in projects {
                    try await project.saveBeforeClosing()
                }
                if !MLXRuntime.beginTermination() {
                    await MLXRuntime.waitUntilIdle()
                }
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                projects.forEach { $0.editorViewModel.projectPackageCoordinator.cancelClosing() }
                isTerminating = false
                sender.presentError(error)
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    @MainActor
    @objc func newProject(_ sender: Any?) {
        AppState.shared.createProjectInteractively()
    }

    @MainActor
    @objc func openProject(_ sender: Any?) {
        AppState.shared.openProjectFromPanel()
    }

    @MainActor
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @MainActor
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .shortcuts)
    }

    @MainActor
    @objc func showMCPInstructions(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .mcp)
    }

    @MainActor
    @objc func showFeedback(_ sender: Any?) {
        FeedbackWindowController.shared.show()
    }

    @MainActor
    @objc func showSupport(_ sender: Any?) {
        SupportLink.open()
    }

    // Temporary: replay the full first-run flow without a fresh account.
    @MainActor
    @objc func previewFirstRun(_ sender: Any?) {
        UserDefaults.standard.removeObject(forKey: "hasSeenWelcome")
        TourController.resetFirstRun()
        OnboardingWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    @objc func showTutorial(_ sender: Any?) {
        guard let editor = AppState.shared.activeProject?.editorViewModel else { return }
        editor.tour.start(in: editor)
    }

    @MainActor
    @objc func signIn(_ sender: Any?) {
        SignInWindowController.shared.showWindow(nil)
        SignInWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    @objc func signOut(_ sender: Any?) {
        Task { await SupabaseService.shared.signOut() }
    }

    @MainActor
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(signIn(_:)): return !SupabaseService.shared.isSignedIn
        case #selector(signOut(_:)): return SupabaseService.shared.isSignedIn
        default: return true
        }
    }
}
