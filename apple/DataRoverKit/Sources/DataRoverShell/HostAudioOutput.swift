import AVFAudio
import Foundation

/// Pulls guest PCM from the core on AVAudioEngine's realtime render thread.
/// The callback performs no allocation, locking, or logging.
final class HostAudioOutput {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let handle: UnsafeMutableRawPointer
    private let scratch: UnsafeMutablePointer<Int16>
    private let capacity = 2_048

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
        scratch = .allocate(capacity: capacity)
        scratch.initialize(repeating: 0, count: capacity)
    }

    @discardableResult func start() -> Bool {
        guard source == nil else { return true }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let node = AVAudioSourceNode { [handle, scratch, capacity] _, _, frameCount, audioBufferList -> OSStatus in
            let requested = min(Int(frameCount), capacity)
            let count = coreAudioRead(handle, into: scratch, capacity: requested)
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if let samples = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
                for index in 0..<requested {
                    samples[index] = index < count ? Float(scratch[index]) / 32768.0 : 0
                }
                if requested < Int(frameCount) {
                    for index in requested..<Int(frameCount) { samples[index] = 0 }
                }
            }
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start(); return true } catch { stop(); return false }
    }

    func stop() {
        engine.stop()
        if let source {
            engine.disconnectNodeOutput(source)
            engine.detach(source)
            self.source = nil
        }
        coreAudioClear(handle)
    }

    deinit {
        engine.stop()
        scratch.deinitialize(count: capacity)
        scratch.deallocate()
    }
}
