import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkey: HotkeyMonitor!
    private var recorder: AudioRecorder!
    private var engine: TranscriptionEngine!
    private var coordinator: TranscriptionCoordinator!
    private var store: HistoryStore!
    private var metrics: MetricsEngine!
    private var overlay: OverlayWindow!
    private var menu: MenuBarController!
    private var popoverVM: PopoverViewModel!
    private var prefsWin: PreferencesWindowController?
    /// Numbers the tab requests, see PrefsTabRequest.
    private var prefsTabSerial = 0
    private var onboardingWin: NSWindow?
    /// Set while the onboarding window is up; refreshed by `onboardingTimer` and activation.
    private var onboardingPerms: OnboardingPermissions?
    private var onboardingTimer: Timer?
    private var onboardingCloseObserver: NSObjectProtocol?
    private var modelsVM: ModelsViewModel!
    private var cancellables = Set<AnyCancellable>()
    /// Last values acted on, so unrelated defaults writes don't re-trigger them.
    private var appliedPrimaryLanguage: PrimaryLanguage?
    private var appliedLocalModel: LocalModel?
    private var appliedEngine: TranscriptionEngineKind?
    /// Counts holds; `recorderFailedTake` is the hold a recorder failure arrived during,
    /// whose reason is already in the HUD.
    private var take = 0
    private var recorderFailedTake: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else, above all before the event tap is installed.
        if anotherInstanceIsRunning() {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        PreferencesStore.shared.applyAppearance()
        // Read the API keys now, off main, so the first cloud dictation doesn't block the
        // run loop (and the event tap on it) on a Keychain prompt. Only with a cloud
        // engine selected: the fallback chain starts from one, and a user of the local
        // engines must not be asked for Keychain access at all.
        if PreferencesStore.shared.engineChosen, PreferencesStore.shared.engine.cloudProvider != nil {
            PreferencesStore.shared.warmAPIKeys()
        }
        Self.migrateLegacyAppSupportDirectory()
        Self.removeLegacyLog()

        let historyURL = HistoryStore.defaultURL()
        do {
            store = try HistoryStore(url: historyURL)
        } catch {
            pttLog("Failed to open history DB: \(error)")
            guard let fresh = recoverHistory(at: historyURL, error: error) else {
                NSApp.terminate(nil)
                return
            }
            store = fresh
        }
        metrics = MetricsEngine(store: store, resetAnchor: {
            Int64(PreferencesStore.shared.metricsResetAtMs)
        })
        recorder = AudioRecorder()
        engine = TranscriptionEngine()
        coordinator = TranscriptionCoordinator(engine: engine, store: store)
        coordinator.onModelFallback = { [weak self] notice in
            guard let self else { return }
            self.overlay.flash(AnyView(HUDMessageView(title: notice.title, detail: notice.body,
                                                      symbol: "arrow.triangle.2.circlepath", tint: .yellow)),
                               anchor: self.menu.statusItemFrame, seconds: 4)
        }
        modelsVM = ModelsViewModel()
        engine.onBackupDownloadNeeded = { [weak self] id in
            guard let self, !self.modelsVM.downloading else { return }
            Task { await self.modelsVM.download(id) }
        }
        modelsVM.onDownloaded = { [weak self] model in
            let prefs = PreferencesStore.shared
            guard prefs.engine.isLocal, model == prefs.localModel else { return }
            self?.loadModel(model)
        }
        modelsVM.onDeleted = { [weak self] in
            guard let self else { return }
            self.engine.unloadLocal()
            // The selected model may still be found in another app's folder.
            let prefs = PreferencesStore.shared
            if prefs.engine.isLocal, ModelManager.shared.locate(prefs.localModel) != nil {
                self.loadModel(prefs.localModel)
            }
        }
        popoverVM = PopoverViewModel(store: store, metricsEngine: metrics)
        menu = MenuBarController(viewModel: popoverVM)
        overlay = OverlayWindow(content: AnyView(hudView()))
        hotkey = HotkeyMonitor()

        bind()
        applyPrimaryLanguageToTerminology()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDefaultsChange() }
        }

        // Installs from before the engine choice existed downloaded a Whisper model
        // on first launch: keep them on Whisper instead of asking again.
        let prefs = PreferencesStore.shared
        if !prefs.engineChosen, ModelManager.shared.hasManagedModels() {
            prefs.engine = .whisper
        }
        appliedLocalModel = prefs.localModel
        appliedEngine = prefs.engineChosen ? prefs.engine : nil
        // A fresh install loads nothing until onboarding picks an engine; the cloud engines
        // never need a local model in memory (~1.5 GB for Whisper Turbo). A model that
        // isn't on disk is not fetched here: the user may have deleted it on purpose, and
        // a download belongs in Preferences, where its progress shows.
        if prefs.engineChosen, prefs.engine.isLocal {
            if ModelManager.shared.locate(prefs.localModel) != nil {
                loadModel(prefs.localModel)
            } else {
                pttLog("Model \(prefs.localModel.shortLabel) not downloaded — waiting for a download in Preferences")
            }
        }

        NotificationCenter.default.addObserver(forName: .openPreferences, object: nil, queue: .main) { [weak self] note in
            // No tab named (gear button, ⌘,): an open window stays on its tab.
            let tab = (note.object as? String).flatMap(PrefsTab.init(rawValue:))
            Task { @MainActor in self?.showPreferences(tab: tab) }
        }

        handlePermissionsAndStart()

        Task { await popoverVM.checkForUpdates() }
    }

    /// A second copy would install a second event tap and type every dictation twice,
    /// so it quits quietly. Opening the running .app again never gets here: LaunchServices
    /// sends that copy a reopen instead (applicationShouldHandleReopen). A copy at another
    /// path (the DMG next to /Applications, a build folder) or `open -n` starts a second
    /// process, and that one yields to whichever started first.
    private func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let current = NSRunningApplication.current
        let me = SingleInstance.Instance(pid: current.processIdentifier, launchDate: current.launchDate)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map { SingleInstance.Instance(pid: $0.processIdentifier, launchDate: $0.launchDate) }
        // LaunchServices' list can still hold a copy that is on its way out (a relaunch
        // right after Quit or pkill), and it isn't refreshed while main is blocked here:
        // ask the kernel whether that process still exists, for up to a second.
        let deadline = Date().addingTimeInterval(1)
        while let running = SingleInstance.instanceToYieldTo(me: me, others: others.filter { Self.processExists($0.pid) }) {
            if Date() >= deadline {
                pttLog("HoldSpeak is already running (pid \(running.pid)); quitting this copy (pid \(me.pid)) at \(Bundle.main.bundlePath)")
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The history database didn't open: asks whether to set it aside and start empty,
    /// instead of quitting silently on every launch. Nil when the user quits, or when a
    /// fresh database can't be opened either (said in a second alert).
    private func recoverHistory(at url: URL, error: Error) -> HistoryStore? {
        // An accessory app's alert stays behind the frontmost app unless it activates.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "HoldSpeak can't open its history"
        alert.informativeText = "The history file is damaged or unreadable; starting empty keeps the old file in the same folder.\n\n\(error)"
        alert.addButton(withTitle: "Start with empty history")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else {
            pttLog("History DB: quitting at the user's choice")
            return nil
        }
        do {
            let moved = try HistoryRecovery.moveAside(url)
            pttLog("History DB set aside: \(moved.map(\.lastPathComponent).joined(separator: ", "))")
            return try HistoryStore(url: url)
        } catch {
            pttLog("History DB: starting empty failed: \(error)")
            let failed = NSAlert()
            failed.alertStyle = .critical
            failed.messageText = "HoldSpeak can't start with an empty history"
            failed.informativeText = "HoldSpeak will quit. The history is in ~/Library/Application Support/HoldSpeak.\n\n\(error)"
            failed.addButton(withTitle: "Quit")
            failed.runModal()
            return nil
        }
    }

    private func handlePermissionsAndStart() {
        hotkey.start()
        let perms = PermissionsManager.shared.current()
        if !perms.allGranted || !PreferencesStore.shared.engineChosen { showOnboarding() }
    }

    private func showOnboarding() {
        let perms = OnboardingPermissions()
        let content = OnboardingView(
            modelsVM: modelsVM,
            permissions: perms,
            needsEngine: !PreferencesStore.shared.engineChosen,
            onEngineChosen: { [weak self] kind in self?.chooseEngine(kind) },
            // The rest happens in onboardingClosed, which the red button reaches too.
            onDone: { [weak self] in self?.onboardingWin?.close() }
        )
        let hc = NSHostingController(rootView: content)
        let win = NSWindow(contentViewController: hc)
        win.title = "Welcome"
        win.styleMask = [.titled, .closable]
        // Held in onboardingWin; a release on close as well would over-release it.
        win.isReleasedWhenClosed = false
        win.center()
        onboardingWin = win
        onboardingPerms = perms
        onboardingCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onboardingClosed() }
        }
        // Granting a permission happens in System Settings; poll so the rows and Done
        // follow without "Re-check". Stopped in onboardingClosed.
        onboardingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshOnboardingPermissions() }
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshOnboardingPermissions() {
        guard let perms = onboardingPerms else { return }
        perms.refresh()
        // Accessibility granted while the window is up: the hotkey works before Done.
        // A no-op once the tap is running.
        if perms.current.accessibility { hotkey.start() }
    }

    /// Done or the red button. The event tap couldn't be created at launch without
    /// Accessibility, so try again now that the user may have granted it.
    private func onboardingClosed() {
        guard onboardingWin != nil else { return }
        onboardingTimer?.invalidate()
        onboardingTimer = nil
        if let observer = onboardingCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        onboardingCloseObserver = nil
        onboardingWin = nil
        onboardingPerms = nil
        hotkey.start()
    }

    /// Opening the app again while it runs (Finder, Spotlight, Launchpad, `open`) arrives
    /// here, not as a second process. With the menu bar icon hidden (notch, menu bar
    /// managers) it is the only way back to Preferences; during onboarding it brings
    /// the onboarding window forward instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launch isn't finished (the history alert is up, or this copy is quitting).
        guard popoverVM != nil else { return false }
        if let win = onboardingWin {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            showPreferences()
        }
        return false
    }

    /// Coming back from System Settings activates the app (a click on its window, the
    /// popover): refresh the onboarding rows, and start the event tap if Accessibility
    /// was granted after launch. `HotkeyMonitor.start()` does nothing while the tap runs.
    func applicationDidBecomeActive(_ notification: Notification) {
        onboardingPerms?.refresh()
        hotkey?.start()
    }

    private func chooseEngine(_ kind: TranscriptionEngineKind) {
        let prefs = PreferencesStore.shared
        prefs.engine = kind
        appliedEngine = kind
        appliedLocalModel = prefs.localModel
        pttLog("Engine chosen in onboarding: \(kind.rawValue)")
        guard kind.isLocal else { return }
        if ModelManager.shared.locate(prefs.localModel) != nil {
            loadModel(prefs.localModel)
        } else {
            // Shows progress in onboarding; onDownloaded loads it.
            Task { await modelsVM.download(prefs.localModel) }
        }
    }

    /// `tab` switches the window to that tab even when it is already open; nil leaves
    /// an open window on its tab and starts a new one on General.
    private func showPreferences(tab: PrefsTab? = nil) {
        if prefsWin == nil { prefsWin = PreferencesWindowController() }
        let request = tab.map { tab -> PrefsTabRequest in
            prefsTabSerial += 1
            return PrefsTabRequest(tab: tab, serial: prefsTabSerial)
        }
        let view = PreferencesView(
            modelsVM: modelsVM,
            historyStore: store,
            onClearHistory: { [weak self] in
                try? self?.store.clear()
                self?.popoverVM.refresh()
            },
            onResetMetrics: { [weak self] in
                PreferencesStore.shared.metricsResetAtMs = Int(Date().timeIntervalSince1970 * 1000)
                self?.popoverVM.refresh()
            },
            tabRequest: request
        )
        prefsWin?.present(view)
    }

    @ViewBuilder private func hudView() -> some View {
        HUDPillView()
    }

    private func showFailure(_ failure: TranscriptionFailure) {
        overlay.flash(AnyView(HUDMessageView(title: failure.title, detail: failure.body)),
                      anchor: menu.statusItemFrame,
                      seconds: failure.displaySeconds)
    }

    /// The text was transcribed and saved but not typed: told in the HUD pill, not a
    /// notification, which the user may have denied.
    private func showNotTyped(_ reason: NotTypedReason) {
        // A revoked permission is a problem to fix, not a miss: orange, and a little
        // longer to read the instruction.
        let problem = reason == .accessibilityOff
        overlay.flash(AnyView(HUDMessageView(title: reason.title, detail: reason.detail,
                                             symbol: reason.symbol, tint: problem ? .orange : .yellow)),
                      anchor: menu.statusItemFrame, seconds: problem ? 6 : 4)
    }

    private func loadModel(_ model: LocalModel) {
        Task {
            pttLog("Preloading model: \(model.shortLabel)")
            do {
                try await engine.preload(model)
                pttLog("Model loaded OK: \(model.shortLabel)")
            } catch {
                pttLog("Model preload FAILED: \(error)")
            }
        }
    }

    private func handleDefaultsChange() {
        let prefs = PreferencesStore.shared
        if prefs.primaryLanguage != appliedPrimaryLanguage {
            applyPrimaryLanguageToTerminology()
        }
        guard prefs.engineChosen else { return }
        let engineChanged = prefs.engine != appliedEngine
        if engineChanged {
            appliedEngine = prefs.engine
            pttLog("Engine switched to \(prefs.engine.rawValue)")
            if !prefs.engine.isLocal { engine.unloadLocal() }
        }
        guard prefs.engine.isLocal else { return }
        let model = prefs.localModel
        if engineChanged || model != appliedLocalModel {
            appliedLocalModel = model
            // A model that isn't on disk yet loads once "Download selected model" finishes.
            if ModelManager.shared.locate(model) != nil {
                loadModel(model)
            } else {
                // The other local engine's model is no use now.
                engine.unloadLocal(except: model.engineKind)
                pttLog("Model \(model.shortLabel) selected but not downloaded — waiting for download")
            }
        }
    }

    private func applyPrimaryLanguageToTerminology() {
        let pref = PreferencesStore.shared.primaryLanguage
        appliedPrimaryLanguage = pref
        // Auto: keep the current list (TerminologyStore starts on the one from the last
        // run) and let per-utterance detection switch it.
        guard let code = pref.whisperCode else { return }
        TerminologyStore.shared.setActiveLanguage(code)
    }

    private func bind() {
        hotkey.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .startHold:  self.startRecording()
                case .endHold:    self.endRecording()
                case .cancelHold: self.cancelRecording()
                }
            }
            .store(in: &cancellables)

        recorder.amplitude
            .receive(on: DispatchQueue.main)
            .sink { amp in
                HUDAmplitudeModel.shared.push(amp)
            }
            .store(in: &cancellables)

        recorder.chunks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buf in
                self?.engine.feed(buf)
            }
            .store(in: &cancellables)

        recorder.failures
            .sink { [weak self] error in
                pttLog("Recorder failure: \(error)")
                guard let self else { return }
                self.recorderFailedTake = self.take
                // Replaces the recording pill, and endRecording's hidePill leaves it up.
                // The take's samples (none, or what came before a mid-take failure) are
                // still drained by endRecording / cancelRecording when the hold ends.
                self.showFailure(.recorder(error))
            }
            .store(in: &cancellables)
    }

    private func startRecording() {
        pttLog("startRecording")
        take += 1
        recorder.start(input: PreferencesStore.shared.inputSelection)
        overlay.update(AnyView(hudView()))
        overlay.show(anchor: menu.statusItemFrame)
    }

    private func cancelRecording() {
        pttLog("cancelRecording (tap shorter than hold threshold)")
        recorder.stop { [weak self] in
            _ = self?.engine.takeSamples() // discard the tap's audio
        }
        overlay.hidePill()
    }

    private func endRecording() {
        pttLog("endRecording")
        overlay.hidePill()
        let take = take
        recorder.stop { [weak self] in
            guard let self else { return }
            // Take the samples now, synchronously: the next recording's chunks can
            // arrive on main as soon as this completion returns.
            let samples = self.engine.takeSamples()
            // The recorder failed this take and the HUD already says why;
            // "No audio captured" would only replace that.
            if samples.isEmpty, self.recorderFailedTake == take {
                pttLog("endRecording: no samples after a recorder failure — nothing to transcribe")
                return
            }
            Task { @MainActor in
                switch await self.coordinator.finishRecording(samples: samples) {
                case .empty:
                    return
                case .skippedSecureField:
                    self.showNotTyped(.secureField)
                case .noFocus:
                    self.showNotTyped(.noFocus(accessibilityTrusted: AXIsProcessTrusted()))
                case .inserted:
                    break
                case .failed(let failure):
                    self.showFailure(failure)
                    return
                }
                self.popoverVM.refresh()
            }
        }
    }

    private static func migrateLegacyAppSupportDirectory() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = base.appendingPathComponent("push-to-talk")
        let target = base.appendingPathComponent("HoldSpeak")
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: target.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: target)
            pttLog("Migrated Application Support: push-to-talk → HoldSpeak")
        } catch {
            pttLog("Migration failed: \(error)")
        }
    }

    /// ~/Library/Logs/PushToTalk.log from before the rename holds old transcripts in
    /// clear text and was never cleaned up.
    private static func removeLegacyLog() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        let removed = removeLegacyLogs(in: logs)
        if !removed.isEmpty {
            pttLog("Removed the log from before the rename: \(removed.joined(separator: ", "))")
        }
    }
}
