import AVFoundation
import MediaToolbox

// Ecualizador de 10 bandas. AVPlayer no trae uno, así que el audio pasa por un
// "tap" (MTAudioProcessingTap) donde se le aplican filtros antes de sonar.
//
// El hilo de audio no puede esperar candados, así que lee las ganancias desde memoria
// compartida simple y recalcula sus filtros cuando cambia el contador de generación.

private let eqBandCount = 10
private let eqGains: UnsafeMutablePointer<Float> = {
    let pointer = UnsafeMutablePointer<Float>.allocate(capacity: eqBandCount)
    pointer.initialize(repeating: 0, count: eqBandCount)
    return pointer
}()
/// [0] = activado (0/1), [1] = generación (sube con cada cambio).
private let eqMeta: UnsafeMutablePointer<Int32> = {
    let pointer = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
    pointer.initialize(repeating: 0, count: 2)
    return pointer
}()

enum Equalizer {
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let range: ClosedRange<Double> = -12...12

    struct Preset: Identifiable, Hashable {
        let name: String
        let gains: [Double]
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Plano", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Más bajos", gains: [7, 6, 5, 3, 1, 0, 0, 0, 0, 0]),
        Preset(name: "Rock", gains: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]),
        Preset(name: "Pop", gains: [-1, 0, 2, 4, 5, 4, 2, 0, -1, -1]),
        Preset(name: "Electrónica", gains: [6, 5, 2, 0, -2, 0, 2, 4, 5, 6]),
        Preset(name: "Voz", gains: [-3, -2, 0, 2, 4, 5, 4, 2, 0, -2]),
        Preset(name: "Acústico", gains: [3, 3, 2, 1, 1, 1, 2, 3, 3, 2]),
        Preset(name: "Agudos claros", gains: [0, 0, 0, 0, 0, 1, 3, 5, 6, 7]),
    ]

    /// Graves, medios y agudos repartidos sobre las 10 bandas.
    static func bands(bass: Double, mid: Double, treble: Double) -> [Double] {
        [bass, bass, bass, bass * 0.5 + mid * 0.5, mid, mid, mid, mid * 0.5 + treble * 0.5, treble, treble]
    }

    /// Publica el ajuste para el hilo de audio.
    static func apply(enabled: Bool, gains: [Double]) {
        for index in 0..<eqBandCount {
            eqGains[index] = Float(index < gains.count ? min(max(gains[index], range.lowerBound), range.upperBound) : 0)
        }
        eqMeta[0] = enabled ? 1 : 0
        eqMeta[1] = eqMeta[1] &+ 1
    }

    /// Conecta el ecualizador a una canción antes de reproducirla.
    static func attach(to item: AVPlayerItem, asset: AVAsset) async {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: nil,
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var created: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &created)
        guard status == noErr, let created else { return }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = created.takeRetainedValue()
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }
}

/// Estado del filtro para una canción; vive en el hilo de audio.
private final class TapContext {
    var sampleRate: Float = 44100
    var channels = 2
    var supported = false
    var interleaved = false
    var generation: Int32 = -1
    var active = false
    var preamp: Float = 1
    /// Por banda: b0, b1, b2, a1, a2.
    var coefficients = [Float](repeating: 0, count: eqBandCount * 5)
    /// Por canal y banda: x1, x2, y1, y2.
    var state = [Float](repeating: 0, count: 2 * eqBandCount * 4)

    func configure(_ format: AudioStreamBasicDescription) {
        sampleRate = Float(format.mSampleRate)
        channels = max(1, Int(format.mChannelsPerFrame))
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        supported = format.mFormatID == kAudioFormatLinearPCM && isFloat && format.mBitsPerChannel == 32 && sampleRate > 0
        state = [Float](repeating: 0, count: channels * eqBandCount * 4)
        generation = -1
    }

    /// Filtros "peaking" de la receta de Robert Bristow-Johnson, una octava por banda.
    private func rebuild() {
        var maxBoost: Float = 0
        var any = false
        for band in 0..<eqBandCount {
            let gain = eqGains[band]
            let frequency = Equalizer.frequencies[band]
            let base = band * 5
            if abs(gain) < 0.05 || frequency >= sampleRate / 2.2 {
                coefficients[base] = 1
                coefficients[base + 1] = 0
                coefficients[base + 2] = 0
                coefficients[base + 3] = 0
                coefficients[base + 4] = 0
                continue
            }
            any = true
            maxBoost = max(maxBoost, gain)
            let amplitude = powf(10, gain / 40)
            let omega = 2 * Float.pi * frequency / sampleRate
            let alpha = sinf(omega) / (2 * 1.41)
            let cosine = cosf(omega)
            let a0 = 1 + alpha / amplitude
            coefficients[base] = (1 + alpha * amplitude) / a0
            coefficients[base + 1] = (-2 * cosine) / a0
            coefficients[base + 2] = (1 - alpha * amplitude) / a0
            coefficients[base + 3] = (-2 * cosine) / a0
            coefficients[base + 4] = (1 - alpha / amplitude) / a0
        }
        active = eqMeta[0] == 1 && any
        // Bajar un poco el volumen general cuando se sube alguna banda, para que no sature.
        preamp = powf(10, (-0.5 * maxBoost) / 20)
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard supported, frames > 0 else { return }
        let current = eqMeta[1]
        if current != generation {
            rebuild()
            generation = current
        }
        guard active else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let channelCount = channels
        let gain = preamp
        coefficients.withUnsafeBufferPointer { coefficient in
            state.withUnsafeMutableBufferPointer { memory in
                if interleaved {
                    guard buffers.count > 0, let data = buffers[0].mData else { return }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let available = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size / channelCount
                    for channel in 0..<channelCount {
                        TapContext.filter(samples, stride: channelCount, offset: channel, frames: min(frames, available),
                                          coefficient: coefficient, memory: memory, channel: channel, preamp: gain)
                    }
                } else {
                    for channel in 0..<min(channelCount, buffers.count) {
                        guard let data = buffers[channel].mData else { continue }
                        let samples = data.assumingMemoryBound(to: Float.self)
                        let available = Int(buffers[channel].mDataByteSize) / MemoryLayout<Float>.size
                        TapContext.filter(samples, stride: 1, offset: 0, frames: min(frames, available),
                                          coefficient: coefficient, memory: memory, channel: channel, preamp: gain)
                    }
                }
            }
        }
    }

    private static func filter(_ samples: UnsafeMutablePointer<Float>, stride: Int, offset: Int, frames: Int,
                               coefficient: UnsafeBufferPointer<Float>, memory: UnsafeMutableBufferPointer<Float>,
                               channel: Int, preamp: Float) {
        guard frames > 0 else { return }
        for band in 0..<eqBandCount {
            let base = band * 5
            let b0 = coefficient[base], b1 = coefficient[base + 1], b2 = coefficient[base + 2]
            let a1 = coefficient[base + 3], a2 = coefficient[base + 4]
            if b0 == 1, b1 == 0, b2 == 0, a1 == 0, a2 == 0 { continue }
            let slot = (channel * eqBandCount + band) * 4
            var x1 = memory[slot], x2 = memory[slot + 1], y1 = memory[slot + 2], y2 = memory[slot + 3]
            var index = offset
            for _ in 0..<frames {
                let x = samples[index]
                let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1
                x1 = x
                y2 = y1
                y1 = y
                samples[index] = y
                index += stride
            }
            // Evitar números diminutos que frenan el procesador cuando hay silencio.
            if abs(y1) < 1e-20 { y1 = 0 }
            if abs(y2) < 1e-20 { y2 = 0 }
            memory[slot] = x1
            memory[slot + 1] = x2
            memory[slot + 2] = y1
            memory[slot + 3] = y2
        }
        var index = offset
        for _ in 0..<frames {
            samples[index] = min(max(samples[index] * preamp, -1), 1)
            index += stride
        }
    }
}

private func context(of tap: MTAudioProcessingTap) -> TapContext {
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, _, tapStorageOut in
    tapStorageOut.pointee = Unmanaged.passRetained(TapContext()).toOpaque()
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    context(of: tap).configure(format.pointee)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferList, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    context(of: tap).process(bufferList, frames: Int(numberFramesOut.pointee))
}
