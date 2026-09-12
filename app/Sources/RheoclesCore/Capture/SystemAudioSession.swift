import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import os

/// The system mix, through a Core Audio process tap on every process,
/// surfaced as a private aggregate device with an IO proc.
///
/// The tap delivers Float32 at the tap's own rate; the writer converts to
/// 48 kHz 24-bit BWF. Needs the "System Audio Recording" grant — macOS asks
/// on the first tap, and the Info.plist key is `NSAudioCaptureUsageDescription`
/// (spec §4 said verify; the dev bundle did).
final class SystemAudioSession: StreamSession, @unchecked Sendable {
    let info: StreamInfo
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AudioStreamBasicDescription?
    private var formatDescription: CMAudioFormatDescription?
    private let sinkLock = OSAllocatedUnfairLock<(any FrameSink)?>(initialState: nil)
    private let frames = OSAllocatedUnfairLock(initialState: 0)

    var sink: (any FrameSink)? {
        get { sinkLock.withLock { $0 } }
        set { sinkLock.withLock { $0 = newValue } }
    }

    var framesSeen: Int { frames.withLock { $0 } }

    init(_ stream: StreamInfo) {
        info = stream
    }

    var active: StreamInfo.Capabilities {
        .init(
            audio: .init(
                sampleRate: format?.mSampleRate ?? 48000,
                channels: Int(format?.mChannelsPerFrame ?? 2)))
    }

    func start() async throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Rheocles system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else {
            throw status == kAudioHardwareIllegalOperationError
                || status == kAudioHardwareUnsupportedOperationError
                ? CaptureError.permissionDenied("system audio recording is not granted (\(status))")
                : CaptureError.deviceUnavailable(
                    "could not create the system audio tap (\(status))")
        }
        tapID = tap

        // The tap's format is what the IO proc will hand us.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            await stop()
            throw CaptureError.deviceUnavailable("could not read the tap format (\(status))")
        }
        format = asbd
        var cmFormat: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil, formatDescriptionOut: &cmFormat)
        formatDescription = cmFormat

        // The aggregate needs a clock. A tap alone has none and its IO proc
        // never fires; the default output device is the natural one — it is
        // what the tap is listening to.
        guard let outputUID = Self.defaultOutputUID() else {
            await stop()
            throw CaptureError.deviceUnavailable(
                "no default output device to clock the system audio tap")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Rheocles system audio",
            kAudioAggregateDeviceUIDKey: "build.artisan.rheocles.systemaudio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else {
            await stop()
            throw CaptureError.deviceUnavailable(
                "could not create the tap's aggregate device (\(status))")
        }
        aggregateID = agg

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) {
            [weak self] _, inputData, inputTime, _, _ in
            self?.deliver(inputData, at: inputTime)
        }
        guard status == noErr, let proc else {
            await stop()
            throw CaptureError.deviceUnavailable("could not attach to the tap (\(status))")
        }
        procID = proc
        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else {
            await stop()
            throw CaptureError.deviceUnavailable("the system audio tap did not start (\(status))")
        }
    }

    /// Wrap the IO proc's buffers in a sample buffer with a host-time PTS,
    /// so the writer sees system audio the way it sees a microphone.
    private func deliver(
        _ bufferList: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>
    ) {
        frames.withLock { $0 += 1 }
        guard let sink, let formatDescription, let format else { return }
        let samples =
            Int(bufferList.pointee.mBuffers.mDataByteSize) / Int(max(format.mBytesPerFrame, 1))
        guard samples > 0 else { return }
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil,
                blockLength: Int(bufferList.pointee.mBuffers.mDataByteSize),
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                dataLength: Int(bufferList.pointee.mBuffers.mDataByteSize), flags: 0,
                blockBufferOut: &block)
                == noErr, let block, let data = bufferList.pointee.mBuffers.mData
        else { return }
        CMBlockBufferReplaceDataBytes(
            with: data, blockBuffer: block, offsetIntoDestination: 0,
            dataLength: Int(bufferList.pointee.mBuffers.mDataByteSize))
        let hostSeconds = Double(time.pointee.mHostTime) * SystemAudioSession.hostTicksToSeconds
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.mSampleRate)),
            presentationTimeStamp: CMTime(seconds: hostSeconds, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard
            CMSampleBufferCreate(
                allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription, sampleCount: samples,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer
        else { return }
        sink.handle(sampleBuffer)
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown
        else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid
        else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static let hostTicksToSeconds: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    func stop() async {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }
}
