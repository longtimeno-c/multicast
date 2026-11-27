import Accelerate
import Foundation

/// Finds when the calibration sweep arrives in a microphone recording.
///
/// The recording is correlated with the sweep. Where the sweep starts, the correlation has a
/// sharp peak; an echo adds a later, usually smaller one; noise adds a floor. The estimate is
/// the FIRST strong peak (the sound that came straight from the speaker, not off a wall), and it
/// is given only when that peak stands well clear of the floor, both the floor of the whole
/// recording and the floor right around the peak. The second matters in a real room: a door, a
/// voice or a key press is far louder than the quiet either side of it and lifts the correlation
/// wherever it falls, but as a broad hump, not a peak a fraction of a millisecond wide. Otherwise
/// the answer is nil: a speaker that can't be heard is reported as such, never guessed at.
///
/// Pure arithmetic on samples: no audio device, no clock. The same type serves a recording made
/// by the Mac or sent over by a phone.
public struct DelayEstimator: Sendable {
    public struct Arrival: Equatable, Sendable {
        /// Seconds from the recording's first sample to the start of the sweep.
        public var seconds: Double
        /// How far the peak stands above the noise floor: peak ÷ floor, the lesser of two floors
        /// (over the whole recording, and just around the peak). Pure noise gives about 4 to 5.
        public var strength: Double
    }

    public var signal: CalibrationSignal
    /// Weaker peaks than this are not believed. Set just above what noise alone reaches: one
    /// sweep at this strength proves little, but a calibration only accepts several sweeps that
    /// agree to within milliseconds (`DelayMeasurement.combine`), which noise does about once in
    /// tens of thousands of tries.
    public var minimumStrength: Double
    /// An earlier peak this close before the strongest one, and at least `directPathRatio` of
    /// it, is taken as the direct sound (the strongest then being a reflection).
    public var directPathSeconds: Double
    public var directPathRatio: Float

    public init(signal: CalibrationSignal = CalibrationSignal(), minimumStrength: Double = 6.5,
                directPathSeconds: Double = 0.03, directPathRatio: Float = 0.5) {
        self.signal = signal
        self.minimumStrength = minimumStrength
        self.directPathSeconds = directPathSeconds
        self.directPathRatio = directPathRatio
    }

    /// The sweep's arrival in `recording` (mono, at `sampleRate`), or nil when it isn't clearly
    /// there. Only a sweep that lies wholly inside the recording can be found.
    public func arrival(in recording: [Float], sampleRate: Double) -> Arrival? {
        analyze(recording, sampleRate: sampleRate)?.arrival
    }

    /// Everything one look at a recording finds: the arrival if there is one, and a picture of
    /// the search for a display.
    public struct Analysis: Equatable, Sendable {
        /// nil when the sweep isn't clearly there.
        public var arrival: Arrival?
        /// The strength of the best candidate, believed or not.
        public var strength: Double
        /// The correlation across the recording in `traceBins` steps, each the strongest value
        /// in its step as a fraction of the overall strongest (0…255). A heard sweep is one
        /// spike over a low floor; noise is grass of even height.
        public var trace: [UInt8]
        /// Root mean square of the recording itself, 0…1 of full scale.
        public var level: Float
    }

    public static let traceBins = 96

    /// nil only when the recording is too short to hold a sweep.
    public func analyze(_ recording: [Float], sampleRate: Double) -> Analysis? {
        let template = signal.template(sampleRate: sampleRate)
        let lags = recording.count - template.count + 1
        guard lags > 8, sampleRate > 0 else { return nil }

        var level: Float = 0
        vDSP_rmsqv(recording, 1, &level, vDSP_Length(recording.count))
        var correlation = [Float](repeating: 0, count: lags)
        recording.withUnsafeBufferPointer { r in
            template.withUnsafeBufferPointer { t in
                vDSP_conv(r.baseAddress!, 1, t.baseAddress!, 1, &correlation, 1, vDSP_Length(lags), vDSP_Length(template.count))
            }
        }
        var magnitude = [Float](repeating: 0, count: lags)
        vDSP_vabs(correlation, 1, &magnitude, 1, vDSP_Length(lags))

        var peak: Float = 0
        var peakIndex: vDSP_Length = 0
        vDSP_maxvi(magnitude, 1, &peak, &peakIndex, vDSP_Length(lags))
        guard peak > 0, peak.isFinite else {
            return Analysis(arrival: nil, strength: 0, trace: [UInt8](repeating: 0, count: Self.traceBins), level: level)
        }
        let trace: [UInt8] = (0..<Self.traceBins).map { bin in
            let from = bin * lags / Self.traceBins, to = max(from + 1, (bin + 1) * lags / Self.traceBins)
            var top: Float = 0
            magnitude.withUnsafeBufferPointer { vDSP_maxv($0.baseAddress! + from, 1, &top, vDSP_Length(min(to, lags) - from)) }
            return UInt8(max(0, min(255, (top / peak * 255).rounded())))
        }

        // Noise floor: the median magnitude is untouched by the peak and by a reverberant tail
        // that fills part of the window. For Gaussian noise, sigma = median(|x|) / 0.6745.
        var sorted = magnitude
        vDSP_vsort(&sorted, vDSP_Length(lags), 1)
        let floor = Double(sorted[lags / 2]) / 0.6745

        // The direct sound: the first sample within reach before the strongest peak that is
        // itself strong, then up to the top of the lobe it belongs to.
        let reach = Int(directPathSeconds * sampleRate)
        var i = max(0, Int(peakIndex) - reach)
        let threshold = peak * directPathRatio
        while i < Int(peakIndex), magnitude[i] < threshold { i += 1 }
        while i + 1 < lags, magnitude[i + 1] > magnitude[i] { i += 1 }

        // Parabola through the top three points, for a fraction of a sample.
        var fraction = 0.0
        if i > 0, i + 1 < lags {
            let a = Double(magnitude[i - 1]), b = Double(magnitude[i]), c = Double(magnitude[i + 1])
            let curve = a - 2 * b + c
            if curve < 0 { fraction = min(0.5, max(-0.5, 0.5 * (a - c) / curve)) }
        }

        // The floor around the peak: the stretch just before it (after it comes the room's
        // echo), or just after when the recording starts too close to it.
        let skip = max(2, Int(0.003 * sampleRate)), span = Int(0.06 * sampleRate)
        var local = Self.rms(magnitude, from: i - skip - span, to: i - skip)
        if local == nil { local = Self.rms(magnitude, from: i + skip, to: i + skip + span) }
        var strength = floor > 0 ? Double(magnitude[i]) / floor : 1000
        if let local, local > 0 { strength = min(strength, Double(magnitude[i]) / local) }
        strength = min(strength, 1000)
        let whole = floor > 0 ? Double(peak) / floor : 1000
        let believed = whole >= minimumStrength && strength >= minimumStrength
        return Analysis(arrival: believed ? Arrival(seconds: (Double(i) + fraction) / sampleRate, strength: strength) : nil,
                        strength: strength, trace: trace, level: level)
    }
}

extension DelayEstimator {
    /// Root mean square of `values[from..<to]`, or nil when less than a sixth of that stretch
    /// lies inside the array.
    static func rms(_ values: [Float], from: Int, to: Int) -> Double? {
        let lower = max(0, from), upper = min(values.count, to)
        guard upper > lower, (upper - lower) * 6 >= to - from else { return nil }
        var result: Float = 0
        values.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + lower, 1, &result, vDSP_Length(upper - lower)) }
        return Double(result)
    }
}

/// What several sweeps played to one speaker add up to.
public enum DelayMeasurement: Equatable, Sendable {
    /// Heard, and the sweeps agree: `seconds` is the median delay, `spreadSeconds` how far the
    /// agreeing sweeps lie apart.
    case measured(seconds: Double, spreadSeconds: Double)
    /// Too few sweeps were heard at all.
    case notHeard
    /// Sweeps were heard but don't agree on when (a speaker dropping out, sound from elsewhere).
    case inconsistent

    /// - Parameters:
    ///   - delays: one entry per sweep played; nil where it wasn't heard.
    ///   - minimumAgreeing: how many sweeps must agree.
    ///   - toleranceSeconds: how close to the median counts as agreeing.
    public static func combine(_ delays: [Double?], minimumAgreeing: Int = 3, toleranceSeconds: Double = 0.002) -> DelayMeasurement {
        let heard = delays.compactMap { $0 }.sorted()
        guard heard.count >= max(1, minimumAgreeing) else { return .notHeard }
        let median = Self.median(heard)
        let agreeing = heard.filter { abs($0 - median) <= toleranceSeconds }
        guard agreeing.count >= minimumAgreeing else { return .inconsistent }
        return .measured(seconds: Self.median(agreeing), spreadSeconds: agreeing.last! - agreeing.first!)
    }

    private static func median(_ sorted: [Double]) -> Double {
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
