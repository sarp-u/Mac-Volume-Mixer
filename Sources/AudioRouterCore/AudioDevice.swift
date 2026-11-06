import CoreAudio
import Foundation

public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let transport: String
    public let transportKind: TransportKind
    public let isOurs: Bool

    public var canOutput: Bool { outputChannels > 0 }
    public var canInput: Bool { inputChannels > 0 }

    init?(id: AudioObjectID) {
        guard let uid = try? id.readString(kAudioDevicePropertyDeviceUID) else { return nil }
        self.id = id
        self.uid = uid
        self.name = (try? id.readString(kAudioObjectPropertyName)) ?? uid
        self.manufacturer = (try? id.readString(kAudioObjectPropertyManufacturer)) ?? ""
        self.inputChannels = id.readBufferListChannelCount(scope: kAudioObjectPropertyScopeInput)
        self.outputChannels = id.readBufferListChannelCount(scope: kAudioObjectPropertyScopeOutput)
        let transportCode: UInt32 = (try? id.read(kAudioDevicePropertyTransportType, as: UInt32.self)) ?? 0
        self.transportKind = TransportKind(code: transportCode)
        self.transport = AudioDevice.transportName(transportCode)
        self.isOurs = uid.hasPrefix(RouteEngine.aggregateUIDPrefix)
    }

    public enum TransportKind: Sendable, Hashable {
        case builtIn
        case usb
        case hdmi
        case displayPort
        case bluetooth
        case airPlay
        case virtual
        case aggregate
        case thunderbolt
        case pci
        case fireWire
        case other

        init(code: UInt32) {
            switch code {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeHDMI: self = .hdmi
            case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            case kAudioDeviceTransportTypeVirtual: self = .virtual
            case kAudioDeviceTransportTypeAggregate: self = .aggregate
            case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
            case kAudioDeviceTransportTypePCI: self = .pci
            case kAudioDeviceTransportTypeFireWire: self = .fireWire
            default: self = .other
            }
        }
    }

    private static func transportName(_ code: UInt32) -> String {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        default: return "Other"
        }
    }
}

public enum AudioDevices {
    public static func all() -> [AudioDevice] {
        let ids: [AudioObjectID] = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices)) ?? []
        return ids.compactMap(AudioDevice.init(id:)).filter { !$0.isOurs }
    }

    public static func outputs() -> [AudioDevice] {
        all().filter(\.canOutput).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func inputs() -> [AudioDevice] {
        all().filter(\.canInput).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func device(uid: String) -> AudioDevice? {
        all().first { $0.uid == uid }
    }

    public static func objectID(forUID uid: String) -> AudioObjectID? {
        all().first { $0.uid == uid }?.id
    }


    public static func defaultOutput() -> AudioDevice? {
        guard let id: AudioObjectID = try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) else {
            return nil
        }
        return AudioDevice(id: id)
    }

    public static func defaultInput() -> AudioDevice? {
        guard let id: AudioObjectID = try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self) else {
            return nil
        }
        return AudioDevice(id: id)
    }

    public static func setDefaultOutput(_ device: AudioDevice) throws {
        try setDefault(device, selector: kAudioHardwarePropertyDefaultOutputDevice, label: "Set default output device")
    }

    public static func setDefaultInput(_ device: AudioDevice) throws {
        try setDefault(device, selector: kAudioHardwarePropertyDefaultInputDevice, label: "Set default input device")
    }

    private static func setDefault(
        _ device: AudioDevice,
        selector: AudioObjectPropertySelector,
        label: String
    ) throws {
        var addr = AudioObjectID.address(selector)
        var value = device.id
        try checked(label) {
            AudioObjectSetPropertyData(
                .system, &addr, 0, nil,
                UInt32(MemoryLayout<AudioObjectID>.size), &value
            )
        }
    }


    private static func volumeElements(of device: AudioDevice) -> [AudioObjectPropertyElement] {
        [kAudioObjectPropertyElementMain, 1, 2]
    }

    public static func volume(of device: AudioDevice) -> Float? {
        for element in volumeElements(of: device) {
            guard device.id.hasProperty(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            ) else { continue }
            if let value: Float32 = try? device.id.read(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element,
                as: Float32.self
            ) {
                return Float(value)
            }
        }
        return nil
    }

    public static func setVolume(_ value: Float, on device: AudioDevice) throws {
        var volume = Float32(max(0, min(1, value)))
        var didSet = false
        var lastError: OSStatus = noErr

        for element in volumeElements(of: device) {
            guard device.id.isSettable(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            ) else { continue }
            var addr = AudioObjectID.address(
                kAudioDevicePropertyVolumeScalar,
                kAudioObjectPropertyScopeOutput,
                element
            )
            let status = AudioObjectSetPropertyData(
                device.id, &addr, 0, nil,
                UInt32(MemoryLayout<Float32>.size), &volume
            )
            if status == noErr {
                didSet = true
                if element == kAudioObjectPropertyElementMain { return }
            } else {
                lastError = status
            }
        }

        guard didSet else {
            throw CoreAudioError(
                status: lastError == noErr ? kAudioHardwareUnknownPropertyError : lastError,
                operation: "Set volume for \(device.name) (the device does not support software volume control)"
            )
        }
    }

    public static func isMuted(_ device: AudioDevice) -> Bool? {
        guard let value: UInt32 = try? device.id.read(
            kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput,
            as: UInt32.self
        ) else { return nil }
        return value != 0
    }

    public static func setMuted(_ muted: Bool, on device: AudioDevice) throws {
        var addr = AudioObjectID.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        try checked("Set mute for \(device.name)") {
            AudioObjectSetPropertyData(
                device.id, &addr, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &value
            )
        }
    }

    public static func observeChanges(queue: DispatchQueue = .main, handler: @escaping () -> Void) -> Any {
        Observer(queue: queue, handler: handler)
    }

    private final class Observer {
        private let queue: DispatchQueue
        private var blocks: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []

        init(queue: DispatchQueue, handler: @escaping () -> Void) {
            self.queue = queue
            let selectors: [AudioObjectPropertySelector] = [
                kAudioHardwarePropertyDevices,
                kAudioHardwarePropertyDefaultOutputDevice,
                kAudioHardwarePropertyDefaultInputDevice,
            ]
            for selector in selectors {
                if let block = AudioObjectID.system.addListener(selector, queue: queue, handler: handler) {
                    blocks.append((selector, block))
                }
            }
        }

        deinit {
            for (selector, block) in blocks {
                AudioObjectID.system.removeListener(selector, queue: queue, block: block)
            }
        }
    }
}
