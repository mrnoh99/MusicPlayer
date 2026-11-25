import Accelerate
import AVFoundation

/// 한 번의 분석 결과 (FFT 스펙트럼)
struct SpectrumFrame {
    let magnitudes: [Float]
    let binHz: Double
    let rms: Float
    let noiseFloor: Float
    let time: Date
}

enum MicError: LocalizedError {
    case permissionDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "마이크 권한이 없습니다. 설정 앱 > 악보 플레이어 에서 마이크를 허용하세요."
        case .unavailable: return "마이크를 사용할 수 없습니다."
        }
    }
}

/// 마이크 입력을 받아 8192 포인트 FFT 로 분석합니다.
final class MicAnalyzer {
    var onFrame: ((SpectrumFrame) -> Void)?

    private let engine = AVAudioEngine()
    private let log2n: vDSP_Length = 13
    private var fftSize: Int { 1 << Int(log2n) }
    private let hop = 2048
    private var ring: [Float] = []
    private var pending = 0
    private var window: [Float]
    private let fftSetup: FFTSetup
    private var sampleRate: Double = 44_100
    private let queue = DispatchQueue(label: "mic.analysis")
    private(set) var isRunning = false

    init() {
        let n = 1 << 13
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        window = w
        fftSetup = vDSP_create_fftsetup(13, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw MicError.permissionDenied }
        AudioSessionManager.configure()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.unavailable }
        sampleRate = format.sampleRate

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            self.queue.async { self.consume(samples) }
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        queue.async {
            self.ring.removeAll()
            self.pending = 0
        }
    }

    // MARK: 분석 (백그라운드 큐)

    private func consume(_ samples: [Float]) {
        ring.append(contentsOf: samples)
        if ring.count > fftSize { ring.removeFirst(ring.count - fftSize) }
        pending += samples.count
        guard ring.count == fftSize, pending >= hop else { return }
        pending = 0
        analyze()
    }

    private func analyze() {
        let n = fftSize
        let half = n / 2

        var rms: Float = 0
        vDSP_rmsqv(ring, 1, &rms, vDSP_Length(n))

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        let setup = fftSetup
        let log2n = self.log2n

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let complex = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complex.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        mags[0] = 0   // DC / 나이퀴스트 자리

        let binHz = sampleRate / Double(n)
        let lo = max(1, Int(60 / binHz)), hi = min(half - 1, Int(4200 / binHz))
        var band = Array(mags[lo...hi])
        band.sort()
        let noise = band.isEmpty ? 0 : band[band.count / 2]

        let frame = SpectrumFrame(magnitudes: mags, binHz: binHz, rms: rms, noiseFloor: noise, time: Date())
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(frame)
        }
    }
}

// MARK: - 음 판정

struct NoteAnalysis {
    /// 기대한 음 중 들린 음
    var matched: Set<Int> = []
    /// 기대하지 않았는데 들린 음 (틀린 음 후보)
    var wrong: [Int] = []
    /// 가장 강한 음 (화면 표시용)
    var loudest: Int?
    var isSilent = true
}

enum NoteMatcher {
    static func frequency(_ midi: Int) -> Double {
        440 * pow(2, Double(midi - 69) / 12)
    }

    static func midi(for freq: Double) -> Int {
        Int((69 + 12 * log2(freq / 440)).rounded())
    }

    /// sensitivity: 0.5(둔감) ~ 2.0(민감)
    static func analyze(_ f: SpectrumFrame, expected: Set<Int>, sensitivity: Double) -> NoteAnalysis {
        var result = NoteAnalysis()
        let mags = f.magnitudes
        let lo = max(1, Int(60 / f.binHz)), hi = min(mags.count - 2, Int(4200 / f.binHz))
        guard hi > lo else { return result }

        var globalMax: Float = 0
        for i in lo...hi where mags[i] > globalMax { globalMax = mags[i] }

        let silenceRMS: Float = 0.003 / Float(sensitivity)
        guard f.rms > silenceRMS, globalMax > f.noiseFloor * 6 else { return result }
        result.isSilent = false

        let threshold = max(f.noiseFloor * Float(10 / sensitivity), globalMax * 0.06)

        /// 주파수 근처(±반음의 절반)의 최대 크기
        func peak(near freq: Double) -> Float {
            let center = freq / f.binHz
            let width = max(1.0, center * 0.029)
            let a = max(1, Int(center - width)), b = min(mags.count - 1, Int(center + width + 1))
            guard a <= b else { return 0 }
            var m: Float = 0
            for i in a...b where mags[i] > m { m = mags[i] }
            return m
        }

        // 1) 기대한 음이 들리는지: 기음 또는 2·3배음
        for n in expected {
            let fr = frequency(n)
            var strength = peak(near: fr)
            strength = max(strength, peak(near: fr * 2) * 0.9)
            if n < 52 { strength = max(strength, peak(near: fr * 3) * 0.8) }
            if strength > threshold { result.matched.insert(n) }
        }

        // 2) 스펙트럼 피크 → 기대한 음의 배음으로 설명되지 않으면 틀린 음 후보
        var peaks: [(freq: Double, mag: Float)] = []
        for i in lo...hi {
            let m = mags[i]
            guard m > threshold * 1.4, m >= mags[i - 1], m > mags[i + 1] else { continue }
            // 포물선 보간으로 정확한 주파수
            let a = Double(mags[i - 1]), b = Double(m), c = Double(mags[i + 1])
            let denom = a - 2 * b + c
            let offset = denom == 0 ? 0 : 0.5 * (a - c) / denom
            peaks.append((freq: (Double(i) + offset) * f.binHz, mag: m))
        }
        peaks.sort { $0.mag > $1.mag }
        let strong = peaks.prefix(10).filter { $0.mag > globalMax * 0.22 }
        if let top = strong.first { result.loudest = midi(for: top.freq) }

        func cents(_ a: Double, _ b: Double) -> Double { abs(1200 * log2(a / b)) }
        func explained(_ freq: Double, by notes: [Int]) -> Bool {
            for n in notes {
                let f0 = frequency(n)
                for h in 1...8 where cents(freq, f0 * Double(h)) < 45 { return true }
            }
            return false
        }

        var wrongCandidates: [(midi: Int, freq: Double)] = []
        for p in strong where !explained(p.freq, by: Array(expected)) {
            wrongCandidates.append((midi(for: p.freq), p.freq))
        }
        // 다른 후보의 배음이면 제외 (낮은 음 우선)
        wrongCandidates.sort { $0.freq < $1.freq }
        var kept: [Int] = []
        for c in wrongCandidates {
            if explained(c.freq, by: kept) { continue }
            if !kept.contains(c.midi) && (21...108).contains(c.midi) { kept.append(c.midi) }
        }
        result.wrong = kept
        return result
    }
}
