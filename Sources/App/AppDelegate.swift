import AppKit
import AVFoundation
import Combine
import SwiftUI
@preconcurrency import UserNotifications

func pttLog(_ msg: String) {
    NSLog("[PTT] \(msg)")
    let path = ("~/Library/Logs/PushToTalk.log" as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: path)
    let line = "\(Date()) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: path) {
        try? data.write(to: url)
        return
    }
    if let fh = try? FileHandle(forWritingTo: url) {
        try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
        try? fh.close()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkey: HotkeyMonitor!
    private var recorder: AudioRecorder!
    private var engine: TranscriptionEngine!
    private var store: HistoryStore!
    private var metrics: MetricsEngine!
    private var overlay: OverlayWindow!
    private var menu: MenuBarController!
    private var popoverVM: PopoverViewModel!
    private var prefsWin: PreferencesWindowController?
    private var onboardingWin: NSWindow?
    private var modelsVM: ModelsViewModel!
    private var cancellables = Set<AnyCancellable>()
    private var currentAmplitude: Float = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PreferencesStore.shared.applyAppearance()

        do {
            store = try HistoryStore(url: HistoryStore.defaultURL())
        } catch {
            NSLog("Failed to open history DB: \(error)")
            NSApp.terminate(nil)
            return
        }
        metrics = MetricsEngine(store: store)
        recorder = AudioRecorder()
        engine = TranscriptionEngine()
        modelsVM = ModelsViewModel()
        popoverVM = PopoverViewModel(store: store, metricsEngine: metrics)
        menu = MenuBarController(viewModel: popoverVM)
        overlay = OverlayWindow(content: AnyView(hudView()))
        hotkey = HotkeyMonitor()

        bind()

        Task {
            let modelID = PreferencesStore.shared.modelID
            pttLog("Preloading model: \(modelID.rawValue)")
            do {
                try await engine.preload(model: modelID)
                pttLog("Model loaded OK: \(modelID.rawValue)")
            } catch {
                pttLog("Model preload FAILED: \(error)")
            }
        }

        NotificationCenter.default.addObserver(forName: .openPreferences, object: nil, queue: .main) { [weak self] note in
            let tab = (note.object as? String).flatMap(PrefsTab.init(rawValue:)) ?? .general
            Task { @MainActor in self?.showPreferences(initialTab: tab) }
        }

        handlePermissionsAndStart()

        Task { await popoverVM.checkForUpdates() }
    }

    private func handlePermissionsAndStart() {
        hotkey.start()
        let perms = PermissionsManager.shared.current()
        if !perms.allGranted { showOnboarding() }
    }

    private func showOnboarding() {
        let content = OnboardingView { [weak self] in
            self?.onboardingWin?.close()
            self?.onboardingWin = nil
            self?.hotkey.start()
        }
        let hc = NSHostingController(rootView: content)
        let win = NSWindow(contentViewController: hc)
        win.title = "Welcome"
        win.styleMask = [.titled, .closable]
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWin = win
    }

    private func showPreferences(initialTab: PrefsTab = .general) {
        if prefsWin == nil { prefsWin = PreferencesWindowController() }
        let view = PreferencesView(
            modelsVM: modelsVM,
            historyStore: store,
            onClearHistory: { [weak self] in
                try? self?.store.clear()
                self?.popoverVM.refresh()
            },
            initialTab: initialTab
        )
        prefsWin?.present(view)
    }

    @ViewBuilder private func hudView() -> some View {
        HUDPillView()
    }

    private func bind() {
        hotkey.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .startHold: self.startRecording()
                case .endHold:   self.endRecording()
                }
            }
            .store(in: &cancellables)

        recorder.amplitude
            .receive(on: DispatchQueue.main)
            .sink { [weak self] amp in
                guard let self else { return }
                self.currentAmplitude = amp
                HUDAmplitudeModel.shared.push(amp)
            }
            .store(in: &cancellables)

        recorder.chunks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buf in
                self?.engine.feed(buf)
            }
            .store(in: &cancellables)

    }

    private func startRecording() {
        pttLog("startRecording")
        engine.beginStream()
        do {
            try recorder.start()
        } catch {
            pttLog("Recorder start failed: \(error)")
            return
        }
        menu.setRecording(true)
        overlay.update(AnyView(hudView()))
        overlay.show(anchor: menu.statusItemFrame)
    }

    private func endRecording() {
        pttLog("endRecording")
        _ = recorder.stop()
        menu.setRecording(false)
        overlay.hide()

        Task { @MainActor in
            let startNs = DispatchTime.now().uptimeNanoseconds
            let result: (text: String, language: String?, durationMs: Int)?
            if PreferencesStore.shared.fastInsert {
                await engine.awaitStream(timeoutMs: 400)
                let raw = engine.partialText
                if !raw.isEmpty {
                    result = (raw, nil, engine.currentDurationMs)
                    pttLog("fast: used streaming partial (\(raw.count) chars)")
                } else {
                    pttLog("fast: partial empty, falling back to finalize")
                    result = await engine.finalize()
                }
            } else {
                result = await engine.finalize()
            }
            guard let result = result else {
                pttLog("finalize returned nil (model not loaded or empty audio)")
                return
            }
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
            pttLog("result raw: \"\(result.text)\" lang=\(result.language ?? "?") durMs=\(result.durationMs) elapsedMs=\(elapsedMs)")
            let cleaned = TextCleaner.clean(result.text)
            pttLog("cleaned: \"\(cleaned)\"")
            guard !cleaned.isEmpty else { return }
            let wordCount = cleaned.split(whereSeparator: { $0.isWhitespace }).count
            let insertion = TextInserter.insert(cleaned)
            pttLog("insertion: \(insertion)")
            let record = TranscriptionRecord(
                id: nil,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000),
                rawText: result.text,
                cleanedText: cleaned,
                durationMs: result.durationMs,
                wordCount: wordCount,
                language: result.language,
                inserted: insertion == .inserted
            )
            _ = try? store.append(record)
            switch insertion {
            case .skippedSecureField:
                notify("Skipped password field", "Transcript saved to history.")
            case .noFocus:
                notify("No focused input", "Transcript saved to history.")
            case .inserted:
                break
            }
            popoverVM.refresh()
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            if granted {
                UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
            }
        }
    }
}
