import AudioToolbox
import CoreAudio
import Foundation

struct RouteParameters {
    var volume: Float32 = 1
    var muted: Int32 = 0
    var balance: Float32 = 0
    var meterLeft: Float32 = 0
    var meterRight: Float32 = 0
    var ioProcCalls: Int64 = 0
    var lastInputBuffers: Int32 = 0
    var lastOutputBuffers: Int32 = 0
    var lastInputFrames: Int32 = 0
    var lastOutputFrames: Int32 = 0
    var rawInputPeak: Float32 = 0
    var bailReason: Int32 = 0
    var diagnosticsEnabled: Int32 = 0
}

public final class RouteEngine {
    public static let aggregateUIDPrefix = "com.ugursarp.soundboard.aggregate."

    public enum SourceBehavior {
        case muteOriginal
        case keepOriginal
    }

    public let label: String
    public private(set) var processObjectIDs: [AudioObjectID]
    public private(set) var outputDeviceUID: String
    public var sourceBehavior: SourceBehavior = .muteOriginal

    public var diagnosticsEnabled: Bool {
        get { parameters.pointee.diagnosticsEnabled != 0 }
        set { parameters.pointee.diagnosticsEnabled = newValue ? 1 : 0 }
    }

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let parameters: UnsafeMutablePointer<RouteParameters>
    private let ioQueue: DispatchQueue

    public init(label: String, processObjectIDs: [AudioObjectID], outputDeviceUID: String) {
        self.label = label
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        self.parameters = UnsafeMutablePointer<RouteParameters>.allocate(capacity: 1)
        self.parameters.initialize(to: RouteParameters())
        self.ioQueue = DispatchQueue(label: "com.ugursarp.soundboard.io.\(label)", qos: .userInteractive)
    }

    deinit {
        stop()
        parameters.deinitialize(count: 1)
        parameters.deallocate()
    }


    public var volume: Float {
        get { Float(parameters.pointee.volume) }
        set { parameters.pointee.volume = Float32(max(0, min(1, newValue))) }
    }

    public var isMuted: Bool {
        get { parameters.pointee.muted != 0 }
        set { parameters.pointee.muted = newValue ? 1 : 0 }
    }

    public var balance: Float {
        get { Float(parameters.pointee.balance) }
        set { parameters.pointee.balance = Float32(max(-1, min(1, newValue))) }
    }

    public var levels: (left: Float, right: Float) {
        (Float(parameters.pointee.meterLeft), Float(parameters.pointee.meterRight))
    }

    public var isRunning: Bool { ioProcID != nil }

    public struct Diagnostics {
        public var ioProcCalls: Int
        public var inputBuffers: Int
        public var outputBuffers: Int
        public var inputFrames: Int
        public var outputFrames: Int
        public var rawInputPeak: Float
        public var bailReason: Int
        public var tapFormat: String
        public var outputFormat: String
        public var inputBufferOffset: Int
    }

    public private(set) var tapFormatSummary = "—"
    public private(set) var outputFormatSummary = "—"
    public private(set) var inputBufferOffset = 0

    public var diagnostics: Diagnostics {
        let p = parameters.pointee
        return Diagnostics(
            ioProcCalls: Int(p.ioProcCalls),
            inputBuffers: Int(p.lastInputBuffers),
            outputBuffers: Int(p.lastOutputBuffers),
            inputFrames: Int(p.lastInputFrames),
            outputFrames: Int(p.lastOutputFrames),
            rawInputPeak: Float(p.rawInputPeak),
            bailReason: Int(p.bailReason),
            tapFormat: tapFormatSummary,
            outputFormat: outputFormatSummary,
            inputBufferOffset: inputBufferOffset
        )
    }


    public func start() throws {
        guard !isRunning else { return }
        do {
            try createTap()
            try createAggregateDevice()
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    public func setOutputDevice(uid: String) throws {
        guard uid != outputDeviceUID else { return }
        let wasRunning = isRunning
        stop()
        outputDeviceUID = uid
        if wasRunning { try start() }
    }

    public func setProcesses(_ ids: [AudioObjectID]) throws {
        guard ids != processObjectIDs else { return }
        let wasRunning = isRunning
        stop()
        processObjectIDs = ids
        if wasRunning { try start() }
    }


    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "Soundboard – \(label)"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = sourceBehavior == .muteOriginal ? .muted : .unmuted

        var id = AudioObjectID.unknown
        try checked("Create process tap") { AudioHardwareCreateProcessTap(description, &id) }
        guard id.isValid else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "Create process tap")
        }
        tapID = id
    }

    private func createAggregateDevice() throws {
        let tapUID = try tapID.readString(kAudioTapPropertyUID, label: "Read tap UID")
        let uid = Self.aggregateUIDPrefix + UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Soundboard \(label)",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID],
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]

        var id = AudioObjectID.unknown
        try checked("Create aggregate device") {
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        }
        guard id.isValid else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "Create aggregate device")
        }
        aggregateID = id
    }

    private func startIO() throws {
        let tapFormat: AudioStreamBasicDescription = try tapID.read(
            kAudioTapPropertyFormat, label: "Read tap audio format"
        )
        let outputFormat = try aggregateOutputFormat()

        guard tapFormat.isFloat32, outputFormat.isFloat32 else {
            throw CoreAudioError(
                status: kAudioHardwareUnsupportedOperationError,
                operation: "Validate stream format (only 32-bit float is supported; tap: \(tapFormat.debugSummary), output: \(outputFormat.debugSummary))"
            )
        }

        let inputOffset = AudioDevices.objectID(forUID: outputDeviceUID)
            .map { $0.readBufferListCounts(scope: kAudioObjectPropertyScopeInput).buffers } ?? 0

        tapFormatSummary = tapFormat.debugSummary
        outputFormatSummary = outputFormat.debugSummary
        self.inputBufferOffset = inputOffset

        let parameters = self.parameters
        let block: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
            RouteEngine.render(
                input: inputData,
                inputFormat: tapFormat,
                inputBufferOffset: inputOffset,
                output: outputData,
                outputFormat: outputFormat,
                parameters: parameters.pointee,
                parametersStorage: parameters
            )
        }

        var procID: AudioDeviceIOProcID?
        try checked("Create IOProc") {
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue, block)
        }
        ioProcID = procID
        try checked("Start aggregate device") { AudioDeviceStart(aggregateID, procID) }
    }

    private func aggregateOutputFormat() throws -> AudioStreamBasicDescription {
        let streams: [AudioObjectID] = try aggregateID.readArray(
            kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput,
            label: "Read aggregate device output stream"
        )
        guard let first = streams.first else {
            throw CoreAudioError(
                status: kAudioHardwareUnsupportedOperationError,
                operation: "Get aggregate device output stream"
            )
        }
        return try first.read(kAudioStreamPropertyVirtualFormat, label: "Read output stream format")
    }


    private static func render(
        input: UnsafePointer<AudioBufferList>,
        inputFormat: AudioStreamBasicDescription,
        inputBufferOffset: Int,
        output: UnsafeMutablePointer<AudioBufferList>,
        outputFormat: AudioStreamBasicDescription,
        parameters: RouteParameters,
        parametersStorage: UnsafeMutablePointer<RouteParameters>?
    ) {
        let outputList = UnsafeMutableAudioBufferListPointer(output)
        parametersStorage?.pointee.ioProcCalls += 1
        parametersStorage?.pointee.lastOutputBuffers = Int32(outputList.count)

        for buffer in outputList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        parametersStorage?.pointee.lastInputBuffers = Int32(inputList.count)
        let inputChannels = max(1, Int(inputFormat.mChannelsPerFrame))
        let outputChannels = max(1, Int(outputFormat.mChannelsPerFrame))
        let inputNonInterleaved = inputFormat.isNonInterleaved
        let outputNonInterleaved = outputFormat.isNonInterleaved

        let inputBuffersNeeded = inputNonInterleaved ? inputChannels : 1
        guard inputList.count >= inputBufferOffset + inputBuffersNeeded,
              outputList.count >= (outputNonInterleaved ? outputChannels : 1),
              inputFormat.mBytesPerFrame > 0, outputFormat.mBytesPerFrame > 0
        else {
            parametersStorage?.pointee.bailReason = 2
            return
        }

        let inputFrames = Int(inputList[inputBufferOffset].mDataByteSize) / Int(inputFormat.mBytesPerFrame)
        let outputFrames = Int(outputList[0].mDataByteSize) / Int(outputFormat.mBytesPerFrame)
        let frames = min(inputFrames, outputFrames)
        parametersStorage?.pointee.lastInputFrames = Int32(inputFrames)
        parametersStorage?.pointee.lastOutputFrames = Int32(outputFrames)
        guard frames > 0 else {
            parametersStorage?.pointee.bailReason = 3
            return
        }
        parametersStorage?.pointee.bailReason = 0

        let volume = parameters.volume
        let balance = parameters.balance

        @inline(__always)
        func readSample(channel: Int, frame: Int) -> Float32 {
            if inputNonInterleaved {
                guard let data = inputList[inputBufferOffset + channel].mData else { return 0 }
                return data.assumingMemoryBound(to: Float32.self)[frame]
            } else {
                guard let data = inputList[inputBufferOffset].mData else { return 0 }
                return data.assumingMemoryBound(to: Float32.self)[frame * inputChannels + channel]
            }
        }

        @inline(__always)
        func writeSample(_ value: Float32, channel: Int, frame: Int) {
            if outputNonInterleaved {
                guard let data = outputList[channel].mData else { return }
                data.assumingMemoryBound(to: Float32.self)[frame] = value
            } else {
                guard let data = outputList[0].mData else { return }
                data.assumingMemoryBound(to: Float32.self)[frame * outputChannels + channel] = value
            }
        }

        var peak: (Float32, Float32) = (0, 0)
        if parameters.diagnosticsEnabled != 0 {
            var rawPeak: Float32 = 0
            for channel in 0..<inputChannels {
                for frame in 0..<frames {
                    let magnitude = abs(readSample(channel: channel, frame: frame))
                    if magnitude > rawPeak { rawPeak = magnitude }
                }
            }
            parametersStorage?.pointee.rawInputPeak = rawPeak
        }

        guard parameters.muted == 0, parameters.volume > 0 else {
            parametersStorage?.pointee.meterLeft = 0
            parametersStorage?.pointee.meterRight = 0
            parametersStorage?.pointee.bailReason = 1
            return
        }

        for channel in 0..<outputChannels {
            let sourceChannel = channel % inputChannels
            var gain = volume
            if channel == 0, balance > 0 { gain *= (1 - balance) }
            if channel == 1, balance < 0 { gain *= (1 + balance) }

            var channelPeak: Float32 = 0
            for frame in 0..<frames {
                let value = readSample(channel: sourceChannel, frame: frame) * gain
                let magnitude = abs(value)
                if magnitude > channelPeak { channelPeak = magnitude }
                writeSample(max(-1, min(1, value)), channel: channel, frame: frame)
            }
            if channel == 0 { peak.0 = channelPeak }
            if channel == 1 { peak.1 = channelPeak }
        }

        if outputChannels == 1 { peak.1 = peak.0 }
        parametersStorage?.pointee.meterLeft = peak.0
        parametersStorage?.pointee.meterRight = peak.1
    }


    public static func cleanupOrphanedAggregates() {
        let ids: [AudioObjectID] = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices)) ?? []
        for id in ids {
            guard let uid = try? id.readString(kAudioDevicePropertyDeviceUID),
                  uid.hasPrefix(aggregateUIDPrefix) else { continue }
            AudioHardwareDestroyAggregateDevice(id)
        }
    }
}

extension AudioStreamBasicDescription {
    var isFloat32: Bool {
        mFormatID == kAudioFormatLinearPCM
            && (mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && mBitsPerChannel == 32
    }

    var isNonInterleaved: Bool {
        (mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    }

    var debugSummary: String {
        "\(Int(mSampleRate))Hz \(mChannelsPerFrame)ch \(mBitsPerChannel)bit"
            + (isNonInterleaved ? " non-interleaved" : " interleaved")
    }
}
