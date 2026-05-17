import Foundation
import Accelerate
import os

/// Real-time FFT magnitude estimator for the post-EQ signal.
///
/// The audio thread calls `submit` once per IOProc callback to push samples into a
/// fixed-size mono ring buffer (L+R averaged). The main thread calls `snapshot` at
/// UI rate (~30 Hz) to pull a windowed FFT magnitude array out — there's no
/// per-sample work on the audio thread beyond a memcpy.
///
/// The ring is sized to one FFT frame; submissions just overwrite. That means the
/// snapshot always reflects the most recent `fftSize` samples regardless of UI cadence.
final class SpectrumAnalyzer {
    static let fftSize: Int = 4096
    static let binCount: Int = fftSize / 2

    private var ring: [Float]
    private var writeIdx: Int = 0
    private var lock = os_unfair_lock()
    private(set) var sampleRate: Double = 48_000

    // FFT setup and pre-computed Hann window.
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]

    // Work buffers (touched only from `snapshot`, i.e. the main thread).
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]

    init() {
        let n = SpectrumAnalyzer.fftSize
        self.ring = [Float](repeating: 0, count: n)
        self.log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }
        self.fftSetup = setup
        // HANN_DENORM = peak 1, sum ≈ N/2 (standard Hann). Keeps the dBFS
        // calibration math simple: a unit sine at any bin reads 0 dBFS after the
        // 2/N divisor below.
        self.window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        self.windowed = [Float](repeating: 0, count: n)
        self.realp = [Float](repeating: 0, count: n / 2)
        self.imagp = [Float](repeating: 0, count: n / 2)
        self.magnitudes = [Float](repeating: 0, count: n / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func configure(sampleRate: Double) {
        os_unfair_lock_lock(&lock)
        self.sampleRate = sampleRate
        // Don't clear the ring — leftover samples are at most ~85 ms of stale audio
        // (4096 @ 48k) and a tap/output rate change is a near-discontinuity anyway.
        os_unfair_lock_unlock(&lock)
    }

    /// Audio-thread entry: average L+R into the ring at the write cursor. Uses
    /// `trylock` so contention with a UI-thread `snapshot` never blocks the audio
    /// thread — a dropped submission means the next callback's samples overwrite
    /// the same span, which the snapshot reader can't tell apart from normal flow.
    func submit(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        guard os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }

        let cap = ring.count
        var idx = writeIdx
        ring.withUnsafeMutableBufferPointer { buf in
            for i in 0..<frames {
                buf[idx] = 0.5 * (left[i] + right[i])
                idx += 1
                if idx >= cap { idx = 0 }
            }
        }
        writeIdx = idx
    }

    /// Main-thread entry: copy the latest `fftSize` samples out of the ring (unwrapped),
    /// window, FFT, return per-bin magnitudes in dBFS. Always succeeds — on a fresh
    /// engine the ring is zeros and the result is the noise floor.
    func snapshot() -> (magnitudes: [Float], sampleRate: Double) {
        os_unfair_lock_lock(&lock)
        let sr = sampleRate
        let cap = ring.count
        let start = writeIdx % cap
        ring.withUnsafeBufferPointer { src in
            windowed.withUnsafeMutableBufferPointer { dst in
                let first = cap - start
                dst.baseAddress!.update(from: src.baseAddress!.advanced(by: start), count: first)
                if first < cap {
                    dst.baseAddress!.advanced(by: first).update(from: src.baseAddress!, count: cap - first)
                }
            }
        }
        os_unfair_lock_unlock(&lock)

        let halfN = cap / 2

        windowed.withUnsafeMutableBufferPointer { winBuf in
            window.withUnsafeBufferPointer { winCoeff in
                // Apply Hann window in place.
                vDSP_vmul(winBuf.baseAddress!, 1, winCoeff.baseAddress!, 1,
                          winBuf.baseAddress!, 1, vDSP_Length(cap))
            }
            realp.withUnsafeMutableBufferPointer { rePtr in
                imagp.withUnsafeMutableBufferPointer { imPtr in
                    magnitudes.withUnsafeMutableBufferPointer { magPtr in
                        var split = DSPSplitComplex(realp: rePtr.baseAddress!, imagp: imPtr.baseAddress!)
                        // Pack the windowed real samples into split-complex form, run the
                        // in-place radix-2 real FFT, then compute per-bin magnitudes.
                        winBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, magPtr.baseAddress!, 1, vDSP_Length(halfN))

                        // Normalize so a unit sine at bin k reads ~0 dBFS. vDSP's real FFT
                        // doubles the split-real bin magnitudes (2x) and a Hann window
                        // contributes a 0.5 coherent-gain loss, so the per-bin peak for a
                        // unit sine is ~N/2. Divide by N/2 to land at 1.0.
                        var scale: Float = 2.0 / Float(cap)
                        vDSP_vsmul(magPtr.baseAddress!, 1, &scale,
                                   magPtr.baseAddress!, 1, vDSP_Length(halfN))

                        // dBFS = 20·log10(mag + ε). vDSP_vdbcon with flag=1 gives 20·log10.
                        var floor: Float = 1.0e-9
                        vDSP_vsadd(magPtr.baseAddress!, 1, &floor,
                                   magPtr.baseAddress!, 1, vDSP_Length(halfN))
                        var one: Float = 1.0
                        vDSP_vdbcon(magPtr.baseAddress!, 1, &one,
                                    magPtr.baseAddress!, 1, vDSP_Length(halfN), 1)
                    }
                }
            }
        }

        return (magnitudes, sr)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        for i in 0..<ring.count { ring[i] = 0 }
        writeIdx = 0
        os_unfair_lock_unlock(&lock)
    }
}
