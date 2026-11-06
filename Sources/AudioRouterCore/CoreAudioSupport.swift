import CoreAudio
import Foundation

public struct CoreAudioError: LocalizedError, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }

    public var errorDescription: String? { description }

    public var description: String {
        if let code = Self.fourCharCode(status) {
            return "\(operation) failed: '\(code)' (\(status))"
        }
        return "\(operation) failed: \(status)"
    }

    private static func fourCharCode(_ status: OSStatus) -> String? {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
}

protocol _OptionalTypeMarker {}
extension Optional: _OptionalTypeMarker {}

@inline(__always)
func checked(_ operation: String, _ body: () -> OSStatus) throws {
    let status = body()
    guard status == noErr else {
        throw CoreAudioError(status: status, operation: operation)
    }
}

extension AudioObjectID {
    public static let system = AudioObjectID(kAudioObjectSystemObject)
    public static let unknown = AudioObjectID(kAudioObjectUnknown)

    public var isValid: Bool { self != .unknown }

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func isSettable(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var addr = Self.address(selector, scope, element)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(self, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    func hasProperty(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var addr = Self.address(selector, scope, element)
        return AudioObjectHasProperty(self, &addr)
    }

    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        as type: T.Type = T.self,
        label: String? = nil
    ) throws -> T {
        guard !(T.self is _OptionalTypeMarker.Type) else {
            assertionFailure("T was inferred as \(T.self) while reading \(selector.fourCharString); specify the type with as: at the call site")
            throw CoreAudioError(
                status: kAudioHardwareIllegalOperationError,
                operation: "The type was inferred as \(T.self) while reading property \(selector.fourCharString); "
                    + "specify the type with as: at the call site"
            )
        }

        var addr = Self.address(selector, scope, element)
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buffer.deallocate() }
        try checked(label ?? "Read property \(selector.fourCharString)") {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, buffer)
        }
        return buffer.pointee
    }

    func readArray<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        as type: T.Type = T.self,
        label: String? = nil
    ) throws -> [T] {
        var addr = Self.address(selector, scope, element)
        var size: UInt32 = 0
        try checked(label ?? "Get size of property \(selector.fourCharString)") {
            AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size)
        }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }

        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        try checked(label ?? "Read property \(selector.fourCharString)") {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, buffer)
        }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        label: String? = nil
    ) throws -> String {
        var addr = Self.address(selector, scope, element)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        try checked(label ?? "Read string property \(selector.fourCharString)") {
            withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(self, &addr, 0, nil, &size, pointer)
            }
        }
        return (value as String?) ?? ""
    }

    func readBufferListChannelCount(scope: AudioObjectPropertyScope) -> Int {
        var addr = Self.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func readBufferListCounts(scope: AudioObjectPropertyScope) -> (buffers: Int, channels: Int) {
        var addr = Self.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else {
            return (0, 0)
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, raw) == noErr else { return (0, 0) }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return (list.count, list.reduce(0) { $0 + Int($1.mNumberChannels) })
    }

    func addListener(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        queue: DispatchQueue,
        handler: @escaping () -> Void
    ) -> AudioObjectPropertyListenerBlock? {
        var addr = Self.address(selector, scope, element)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(self, &addr, queue, block) == noErr else {
            return nil
        }
        return block
    }

    func removeListener(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var addr = Self.address(selector, scope, element)
        AudioObjectRemovePropertyListenerBlock(self, &addr, queue, block)
    }
}

extension AudioObjectPropertySelector {
    var fourCharString: String {
        let bytes = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
