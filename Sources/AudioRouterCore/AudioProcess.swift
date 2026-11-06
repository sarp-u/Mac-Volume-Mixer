import AppKit
import CoreAudio
import Darwin
import Foundation

public struct AudioProcess: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let name: String
    public let isPlaying: Bool
    public let isRecording: Bool

    init?(objectID: AudioObjectID) {
        guard let pid: pid_t = try? objectID.read(kAudioProcessPropertyPID, as: pid_t.self) else { return nil }
        self.id = objectID
        self.pid = pid

        let rawBundleID = (try? objectID.readString(kAudioProcessPropertyBundleID)) ?? ""
        self.bundleID = rawBundleID.isEmpty ? nil : rawBundleID

        let running = NSRunningApplication(processIdentifier: pid)
        if let localized = running?.localizedName, !localized.isEmpty {
            self.name = localized
        } else if !rawBundleID.isEmpty {
            self.name = rawBundleID.components(separatedBy: ".").last ?? rawBundleID
        } else {
            self.name = AudioProcess.processName(pid: pid) ?? "PID \(pid)"
        }

        let playing: UInt32 = (try? objectID.read(kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0
        let recording: UInt32 = (try? objectID.read(kAudioProcessPropertyIsRunningInput, as: UInt32.self)) ?? 0
        self.isPlaying = playing != 0
        self.isRecording = recording != 0
    }

    init(
        id: AudioObjectID,
        pid: pid_t,
        bundleID: String?,
        name: String,
        isPlaying: Bool,
        isRecording: Bool
    ) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isPlaying = isPlaying
        self.isRecording = isRecording
    }

    private static func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : (path as NSString).lastPathComponent
    }
}

public struct AudioProcessGroup: Identifiable, Hashable, Sendable {
    public let key: String
    public let name: String
    public let bundleID: String?
    public let pid: pid_t
    public let processes: [AudioProcess]
    public let isSystemProcess: Bool

    public var id: String { key }
    public var isPlaying: Bool { processes.contains(where: \.isPlaying) }
    public var isRecording: Bool { processes.contains(where: \.isRecording) }
    public var processObjectIDs: [AudioObjectID] { processes.map(\.id).sorted() }

    @MainActor
    public var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}

public enum AudioProcesses {
    public static func all() -> [AudioProcess] {
        let ids: [AudioObjectID] = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList)) ?? []
        return ids.compactMap(AudioProcess.init(objectID:))
    }

    public static func groups() -> [AudioProcessGroup] {
        var ownerCache: [pid_t: OwningApplication?] = [:]
        return makeGroups(from: all()) { pid in
            if let cached = ownerCache[pid] { return cached }
            let owner = owningApplication(of: pid)
            ownerCache[pid] = owner
            return owner
        }
    }

    static func makeGroups(
        from processes: [AudioProcess],
        resolveOwner: (pid_t) -> OwningApplication?
    ) -> [AudioProcessGroup] {
        var buckets: [String: [AudioProcess]] = [:]
        var owners: [String: OwningApplication?] = [:]

        for process in processes {
            let owner = resolveOwner(process.pid)
            let key = owner?.bundleID ?? process.bundleID ?? "pid:\(process.pid)"
            buckets[key, default: []].append(process)
            if owners[key] == nil { owners[key] = owner }
        }

        let result = buckets.map { key, members -> AudioProcessGroup in
            let owner = owners[key] ?? nil
            let sorted = members.sorted { $0.pid < $1.pid }
            return AudioProcessGroup(
                key: key,
                name: owner?.name ?? sorted[0].name,
                bundleID: owner?.bundleID ?? sorted[0].bundleID,
                pid: (owner?.pid ?? 0) > 0 ? owner!.pid : sorted[0].pid,
                processes: sorted,
                isSystemProcess: !(owner?.isUserApplication ?? false)
            )
        }

        return result.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            if lhs.isSystemProcess != rhs.isSystemProcess { return !lhs.isSystemProcess }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public static func group(key: String) -> AudioProcessGroup? {
        groups().first { $0.key == key }
    }

    public static func search(_ query: String) -> [AudioProcess] {
        let needle = query.lowercased()
        return all().filter { process in
            process.name.lowercased().contains(needle)
                || (process.bundleID?.lowercased().contains(needle) ?? false)
        }
    }

    public static func searchGroups(_ query: String) -> [AudioProcessGroup] {
        let needle = query.lowercased()
        return groups().filter { group in
            group.name.lowercased().contains(needle)
                || (group.bundleID?.lowercased().contains(needle) ?? false)
                || group.processes.contains { $0.name.lowercased().contains(needle) }
        }
    }


    struct OwningApplication {
        let pid: pid_t
        let bundleID: String
        let name: String
        let isUserApplication: Bool
    }

    static func owningApplication(of pid: pid_t) -> OwningApplication? {
        if let fromPath = owningApplicationFromExecutablePath(of: pid) {
            return fromPath
        }
        return owningApplicationFromParentChain(of: pid)
    }

    private static var bundleCache: [String: OwningApplication?] = [:]

    static func owningApplicationFromExecutablePath(of pid: pid_t) -> OwningApplication? {
        guard let path = executablePath(of: pid) else { return nil }
        let components = path.components(separatedBy: "/")
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundlePath = components[0...index].joined(separator: "/")

        let resolved: OwningApplication?
        if let cached = bundleCache[bundlePath] {
            resolved = cached
        } else {
            resolved = readBundle(at: bundlePath)
            bundleCache[bundlePath] = resolved
        }
        guard var owner = resolved else { return nil }

        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: owner.bundleID).first {
            owner = OwningApplication(
                pid: running.processIdentifier,
                bundleID: owner.bundleID,
                name: running.localizedName ?? owner.name,
                isUserApplication: running.activationPolicy == .regular
            )
        }
        return owner
    }

    private static func readBundle(at path: String) -> OwningApplication? {
        guard let bundle = Bundle(path: path), let bundleID = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary
        let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension

        let isUserApplication: Bool
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            isUserApplication = running.activationPolicy == .regular
        } else {
            isUserApplication = !path.hasPrefix("/System/")
        }
        return OwningApplication(
            pid: 0, bundleID: bundleID, name: name, isUserApplication: isUserApplication
        )
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    static func owningApplicationFromParentChain(of pid: pid_t) -> OwningApplication? {
        var current = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular,
               let bundleID = app.bundleIdentifier {
                return OwningApplication(
                    pid: current,
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID,
                    isUserApplication: true
                )
            }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    public static func observeChanges(queue: DispatchQueue = .main, handler: @escaping () -> Void) -> Any {
        Observer(queue: queue, handler: handler)
    }

    public static func observePlaybackState(
        of processObjectIDs: [AudioObjectID],
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) -> PlaybackObserver {
        PlaybackObserver(objectIDs: processObjectIDs, queue: queue, handler: handler)
    }

    public final class PlaybackObserver {
        private let queue: DispatchQueue
        private var blocks: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []

        public var installedCount: Int { blocks.count }

        init(objectIDs: [AudioObjectID], queue: DispatchQueue, handler: @escaping () -> Void) {
            self.queue = queue
            for objectID in objectIDs {
                if let block = objectID.addListener(
                    kAudioProcessPropertyIsRunning, queue: queue, handler: handler
                ) {
                    blocks.append((objectID, block))
                }
            }
        }

        deinit {
            for (objectID, block) in blocks {
                objectID.removeListener(
                    kAudioProcessPropertyIsRunning, queue: queue, block: block
                )
            }
        }
    }

    private final class Observer {
        private let queue: DispatchQueue
        private var block: AudioObjectPropertyListenerBlock?

        init(queue: DispatchQueue, handler: @escaping () -> Void) {
            self.queue = queue
            self.block = AudioObjectID.system.addListener(
                kAudioHardwarePropertyProcessObjectList, queue: queue, handler: handler
            )
        }

        deinit {
            if let block {
                AudioObjectID.system.removeListener(
                    kAudioHardwarePropertyProcessObjectList, queue: queue, block: block
                )
            }
        }
    }
}
