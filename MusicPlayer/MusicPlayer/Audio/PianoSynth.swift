import AVFoundation

enum AudioSessionManager {
    /// 재생과 마이크 입력을 함께 쓰도록 설정 (스피커로 출력)
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true)
        } catch {
            print("오디오 세션 설정 실패: \(error)")
        }
    }
}

/// 배음 합성으로 피아노 비슷한 소리를 만드는 간단한 신시사이저
final class PianoSynth {
    static let shared = PianoSynth()

    private struct Voice {
        let midi: Int
        let freq: Double
        let velocity: Double
        let decay: Double
        var phase: Double = 0
        var t: Double = 0
        var released = false
        var releaseT: Double = 0
        var finished = false
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let lock = NSLock()
    private var voices: [Voice] = []
    private var sampleRate: Double = 44_100
    private var started = false

    private init() {}

    func start() {
        guard !started else {
            if !engine.isRunning { try? engine.start() }
            return
        }
        AudioSessionManager.configure()
        let hwRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = hwRate > 0 ? hwRate : 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            self.render(frames: Int(frameCount), buffers: abl)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.9
        sourceNode = node

        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: .main) { [weak self] _ in
            try? self?.engine.start()
        }
        do {
            try engine.start()
            started = true
        } catch {
            print("오디오 엔진 시작 실패: \(error)")
        }
    }

    func noteOn(_ midi: Int, velocity: Double = 0.8) {
        start()
        let freq = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
        let voice = Voice(midi: midi, freq: freq, velocity: velocity, decay: 0.55 + freq / 380.0)
        lock.lock()
        for i in voices.indices where voices[i].midi == midi { voices[i].released = true }
        voices.append(voice)
        if voices.count > 32 { voices.removeFirst(voices.count - 32) }
        lock.unlock()
    }

    func noteOff(_ midi: Int) {
        lock.lock()
        for i in voices.indices where voices[i].midi == midi { voices[i].released = true }
        lock.unlock()
    }

    func allNotesOff() {
        lock.lock()
        for i in voices.indices { voices[i].released = true }
        lock.unlock()
    }

    /// 편집 중 미리 듣기
    func preview(_ pitches: [Int], seconds: Double = 0.6) {
        pitches.forEach { noteOn($0, velocity: 0.7) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            pitches.forEach { self?.noteOff($0) }
        }
    }

    // MARK: 오디오 스레드

    private func render(frames: Int, buffers: UnsafeMutableAudioBufferListPointer) {
        guard let first = buffers.first, let out = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let dt = 1.0 / sampleRate
        let twoPi = 2.0 * Double.pi
        let attack = 0.004

        lock.lock()
        for i in 0..<frames {
            var mix = 0.0
            for v in voices.indices where !voices[v].finished {
                let t = voices[v].t
                var env = t < attack ? t / attack : exp(-(t - attack) * voices[v].decay)
                if voices[v].released {
                    env *= exp(-voices[v].releaseT * 16)
                    voices[v].releaseT += dt
                }
                if t > attack && env < 0.0005 {
                    voices[v].finished = true
                    continue
                }
                let p = voices[v].phase * twoPi
                var s = sin(p)
                s += 0.50 * sin(2 * p) * exp(-t * 1.5)
                s += 0.28 * sin(3 * p) * exp(-t * 2.5)
                s += 0.15 * sin(4 * p) * exp(-t * 3.5)
                s += 0.07 * sin(5 * p) * exp(-t * 4.5)
                mix += s * env * voices[v].velocity * 0.22

                voices[v].phase += voices[v].freq * dt
                if voices[v].phase >= 1 { voices[v].phase -= 1 }
                voices[v].t = t + dt
            }
            out[i] = Float(tanh(mix))
        }
        voices.removeAll { $0.finished }
        lock.unlock()

        // 혹시 여러 채널이면 복사
        for b in buffers.dropFirst() {
            if let dst = b.mData {
                memcpy(dst, out, min(Int(b.mDataByteSize), frames * MemoryLayout<Float>.size))
            }
        }
    }
}
