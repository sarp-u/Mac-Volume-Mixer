import Combine
import CoreAudio
import Foundation

public struct RouteSettings: Codable, Hashable, Sendable {
    public var outputDeviceUID: String?
    public var volume: Float
    public var muted: Bool
    public var balance: Float
    public var displayName: String

    public init(
        outputDeviceUID: String? = nil,
        volume: Float = 1,
        muted: Bool = false,
        balance: Float = 0,
        displayName: String = ""
    ) {
        self.outputDeviceUID = outputDeviceUID
        self.volume = volume
        self.muted = muted
        self.balance = balance
        self.displayName = displayName
    }

    public var isPassthrough: Bool {
        outputDeviceUID == nil && volume == 1 && !muted && balance == 0
    }
}

public struct RoutedApp: Identifiable, Hashable, Sendable {
    public let key: String
    public let group: AudioProcessGroup?
    public var settings: RouteSettings
    public let isActive: Bool
    public let error: String?
    public let isStarting: Bool
    public let isOutputDeviceOffline: Bool

    public var id: String { key }
    public var name: String { group?.name ?? settings.displayName }
    public var isRunning: Bool { group != nil }
    public var isPlaying: Bool { group?.isPlaying ?? false }
    public var isSystemProcess: Bool { group?.isSystemProcess ?? false }
    public var processCount: Int { group?.processes.count ?? 0 }
}

@MainActor
public final class RouterManager: ObservableObject {
    @Published public private(set) var apps: [RoutedApp] = []
    @Published public private(set) var outputDevices: [AudioDevice] = []
    @Published public private(set) var inputDevices: [AudioDevice] = []
    @Published public private(set) var defaultOutput: AudioDevice?
    @Published public private(set) var defaultInput: AudioDevice?
    @Published public var lastError: String?

    @Published public var showsSystemProcesses = false {
        didSet {
            guard oldValue != showsSystemProcesses else { return }
            rebuildSnapshot()
            updatePlaybackObservers()
        }
    }

    private var settings: [String: RouteSettings] = [:]
    private var engines: [String: RouteEngine] = [:]
    private var engineErrors: [String: String] = [:]
    private var engineTargets: [String: (deviceUID: String, processIDs: [AudioObjectID])] = [:]
    private var failedTargets: [String: (deviceUID: String, processIDs: [AudioObjectID])] = [:]
    private var pendingStarts: Set<String> = []
    private var currentGroups: [AudioProcessGroup] = []

    private var processObserver: Any?
    private var deviceObserver: Any?
    private var playbackObserver: AudioProcesses.PlaybackObserver?
    private var watchedPlaybackIDs: [AudioObjectID] = []
    private let storeURL: URL

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? RouterManager.defaultStoreURL()
        RouteEngine.cleanupOrphanedAggregates()
        loadSettings()
        refresh()

        processObserver = AudioProcesses.observeChanges(queue: .main) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        deviceObserver = AudioDevices.observeChanges(queue: .main) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }


    public func setOutputDevice(_ uid: String?, forKey key: String) {
        mutate(key) { $0.outputDeviceUID = uid }
    }

    public func setVolume(_ volume: Float, forKey key: String) {
        let clamped = max(0, min(1, volume))
        engines[key]?.volume = clamped
        mutate(key) { $0.volume = clamped }
    }

    public func setMuted(_ muted: Bool, forKey key: String) {
        engines[key]?.isMuted = muted
        mutate(key) { $0.muted = muted }
    }

    public func setBalance(_ balance: Float, forKey key: String) {
        let clamped = max(-1, min(1, balance))
        engines[key]?.balance = clamped
        mutate(key) { $0.balance = clamped }
    }

    public func reset(key: String) {
        settings[key]?.outputDeviceUID = nil
        settings[key]?.volume = 1
        settings[key]?.muted = false
        settings[key]?.balance = 0
        saveSettings()
        reconcile()
        rebuildSnapshot()
    }

    public func forget(key: String) {
        settings.removeValue(forKey: key)
        teardownEngine(forKey: key)
        saveSettings()
        rebuildSnapshot()
    }

    public func setSystemDefaultOutput(_ device: AudioDevice) {
        do { try AudioDevices.setDefaultOutput(device) } catch { lastError = "\(error)" }
        refresh()
    }

    public func setSystemDefaultInput(_ device: AudioDevice) {
        do { try AudioDevices.setDefaultInput(device) } catch { lastError = "\(error)" }
        refresh()
    }

    public func settings(forKey key: String) -> RouteSettings {
        settings[key] ?? RouteSettings()
    }


    private func mutate(_ key: String, _ body: (inout RouteSettings) -> Void) {
        var current = settings[key] ?? RouteSettings(displayName: displayName(forKey: key))
        if current.displayName.isEmpty { current.displayName = displayName(forKey: key) }
        body(&current)
        settings[key] = current
        saveSettings()
        reconcile()
        rebuildSnapshot()
    }

    private func displayName(forKey key: String) -> String {
        currentGroups.first { $0.key == key }?.name
            ?? settings[key]?.displayName
            ?? key
    }

    public func refresh() {
        outputDevices = AudioDevices.outputs()
        inputDevices = AudioDevices.inputs()
        defaultOutput = AudioDevices.defaultOutput()
        defaultInput = AudioDevices.defaultInput()
        currentGroups = AudioProcesses.groups()
        reconcile()
        rebuildSnapshot()
        updatePlaybackObservers()
        writeDiagnosticSnapshot()
    }

    private func updatePlaybackObservers() {
        let ids = currentGroups
            .filter { showsSystemProcesses || !$0.isSystemProcess }
            .flatMap(\.processObjectIDs)
            .sorted()

        guard ids != watchedPlaybackIDs else { return }
        watchedPlaybackIDs = ids

        playbackObserver = nil
        playbackObserver = AudioProcesses.observePlaybackState(of: ids, queue: .main) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func writeDiagnosticSnapshot() {
        let all = AudioDevices.all()
        var lines: [String] = []
        lines.append("Time: \(Date())")
        lines.append("Devices: \(all.count) (outputs: \(outputDevices.count), inputs: \(inputDevices.count))")
        lines.append("Default output: \(defaultOutput?.name ?? "nil")")
        lines.append("Default input: \(defaultInput?.name ?? "nil")")
        lines.append("Playback source groups: \(currentGroups.count)")
        lines.append("Displayed apps: \(apps.count) (show system processes: \(showsSystemProcesses))")
        lines.append("Playback observers: \(playbackObserver?.installedCount ?? 0) / \(watchedPlaybackIDs.count) processes")
        lines.append("")
        lines.append("— All devices —")
        for device in all {
            lines.append("  \(device.name)  out\(device.outputChannels) in\(device.inputChannels)  \(device.uid)")
        }
        lines.append("")
        lines.append("— Route status —")
        if apps.allSatisfy({ $0.settings.isPassthrough }) {
            lines.append("  (No custom routes)")
        }
        for app in apps where !app.settings.isPassthrough {
            var parts: [String] = []
            parts.append(app.settings.outputDeviceUID ?? "Follow system output")
            parts.append("Volume \(Int(app.settings.volume * 100))%")
            if app.settings.muted { parts.append("Muted") }
            parts.append(app.isActive ? "Engine running" : "Engine stopped")
            lines.append("  \(app.name): \(parts.joined(separator: ", "))")
            if let error = app.error { lines.append("      Error: \(error)") }
            if app.isStarting { lines.append("      (Starting)") }
            if app.isOutputDeviceOffline { lines.append("      Selected device is offline; temporarily following system output") }
        }
        lines.append("")
        lines.append("— Playback sources —")
        for group in currentGroups {
            lines.append("  \(group.name)  processes: \(group.processes.count)  "
                + "\(group.isPlaying ? "playing" : "idle")\(group.isSystemProcess ? " / system" : "")")
        }

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Soundboard-status.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func reconcile() {
        var groupsByKey: [String: AudioProcessGroup] = [:]
        for group in currentGroups {
            groupsByKey[group.key] = group
        }

        for key in engines.keys where !shouldRunEngine(key: key, group: groupsByKey[key]) {
            teardownEngine(forKey: key)
        }

        for (key, setting) in settings {
            guard let group = groupsByKey[key], shouldRunEngine(key: key, group: group) else { continue }

            let requestedUID = setting.outputDeviceUID
            let requestedIsAvailable = requestedUID.map { uid in
                outputDevices.contains { $0.uid == uid }
            } ?? true

            var effective = setting
            if !requestedIsAvailable { effective.outputDeviceUID = nil }
            guard !effective.isPassthrough else {
                teardownEngine(forKey: key)
                continue
            }

            guard let deviceUID = effective.outputDeviceUID ?? defaultOutput?.uid else { continue }

            let processIDs = group.processObjectIDs
            let target = engineTargets[key]

            if let failed = failedTargets[key],
               failed.deviceUID == deviceUID, failed.processIDs == processIDs {
                continue
            }

            if let engine = engines[key], target?.deviceUID == deviceUID, target?.processIDs == processIDs {
                engine.volume = setting.volume
                engine.isMuted = setting.muted
                engine.balance = setting.balance
                continue
            }

            guard !pendingStarts.contains(key) else { continue }

            teardownEngine(forKey: key)

            let engine = RouteEngine(
                label: setting.displayName.isEmpty ? key : setting.displayName,
                processObjectIDs: processIDs,
                outputDeviceUID: deviceUID
            )
            engine.volume = setting.volume
            engine.isMuted = setting.muted
            engine.balance = setting.balance

            pendingStarts.insert(key)
            let displayName = setting.displayName.isEmpty ? key : setting.displayName
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try engine.start()
                    await self?.engineDidStart(
                        key: key, engine: engine, deviceUID: deviceUID, processIDs: processIDs
                    )
                } catch {
                    await self?.engineDidFail(
                        key: key, deviceUID: deviceUID, processIDs: processIDs,
                        displayName: displayName, message: "\(error)"
                    )
                }
            }
        }
    }

    private func engineDidStart(
        key: String,
        engine: RouteEngine,
        deviceUID: String,
        processIDs: [AudioObjectID]
    ) {
        pendingStarts.remove(key)

        guard engines[key] == nil else {
            engine.stop()
            rebuildSnapshot()
            return
        }

        engines[key] = engine
        engineTargets[key] = (deviceUID, processIDs)
        engineErrors[key] = nil
        failedTargets.removeValue(forKey: key)
        reconcile()
        rebuildSnapshot()
        writeDiagnosticSnapshot()
    }

    private func engineDidFail(
        key: String,
        deviceUID: String,
        processIDs: [AudioObjectID],
        displayName: String,
        message: String
    ) {
        pendingStarts.remove(key)
        engineErrors[key] = message
        failedTargets[key] = (deviceUID, processIDs)
        lastError = "\(displayName)：\(message)"
        rebuildSnapshot()
        writeDiagnosticSnapshot()
    }

    private func shouldRunEngine(key: String, group: AudioProcessGroup?) -> Bool {
        guard let setting = settings[key], !setting.isPassthrough else { return false }
        return group != nil
    }

    private func teardownEngine(forKey key: String) {
        engines[key]?.stop()
        engines.removeValue(forKey: key)
        engineTargets.removeValue(forKey: key)
    }

    private func isOutputDeviceOffline(_ setting: RouteSettings?) -> Bool {
        guard let uid = setting?.outputDeviceUID else { return false }
        return !outputDevices.contains { $0.uid == uid }
    }

    private func rebuildSnapshot() {
        var seen = Set<String>()
        var result: [RoutedApp] = []

        for group in currentGroups {
            let setting = settings[group.key]
            let hasSettings = setting.map { !$0.isPassthrough } ?? false
            guard showsSystemProcesses || !group.isSystemProcess || hasSettings else { continue }

            seen.insert(group.key)
            result.append(RoutedApp(
                key: group.key,
                group: group,
                settings: setting ?? RouteSettings(displayName: group.name),
                isActive: engines[group.key]?.isRunning ?? false,
                error: engineErrors[group.key],
                isStarting: pendingStarts.contains(group.key),
                isOutputDeviceOffline: isOutputDeviceOffline(setting)
            ))
        }

        for (key, setting) in settings where !seen.contains(key) && !setting.isPassthrough {
            result.append(RoutedApp(
                key: key,
                group: nil,
                settings: setting,
                isActive: false,
                error: engineErrors[key],
                isStarting: pendingStarts.contains(key),
                isOutputDeviceOffline: isOutputDeviceOffline(setting)
            ))
        }

        apps = result
    }


    private static func defaultStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soundboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("routes.json")
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: RouteSettings].self, from: data)
        else { return }
        settings = decoded
    }

    private func saveSettings() {
        let persisted = settings.filter { !$0.value.isPassthrough }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(persisted) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
