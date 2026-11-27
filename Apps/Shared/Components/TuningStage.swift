import SwiftUI
import MulticastHubModel

// The tuning of one speaker's sync, drawn from what really happens:
//
//   scene   the speaker, the microphone, and each test sweep travelling between them. A sweep
//           leaves when the hub's timeline says it is due at the loudspeaker and lands a second
//           later, which is when the microphone's answer for it arrives.
//   scope   what the microphone found for each sweep across its listening window: a spike where
//           the sweep arrived over the room's floor. Sweeps stack; when their spikes stand in
//           the same place, the speaker's delay is known.
//   result  how far out the speaker was and the trim that puts it in step, or what to do when
//           it couldn't be heard.
//
// One Canvas per part inside one TimelineView, so it holds 60 fps; nothing moves once the
// tuning has finished. Reduce Motion replaces the travelling sweeps with a row of marks.

private struct TuningFrozenTimeKey: EnvironmentKey {
    static let defaultValue: TimeInterval? = nil
}

extension EnvironmentValues {
    /// Review scenes and snapshots draw the stage as it is this many seconds after the first
    /// sweep left the speaker, and hold it there.
    var mcTuningFrozenTime: TimeInterval? {
        get { self[TuningFrozenTimeKey.self] }
        set { self[TuningFrozenTimeKey.self] = newValue }
    }
}

struct TuningStage: View {
    /// The speaker being tuned (its name and glyph).
    var speaker: SpeakerItem?
    /// The tuning as the hub publishes it; nil before one is asked for.
    var status: SyncCalibrationStatus?
    /// The live sound at this device's own microphone, newest last, when this device is the
    /// one listening.
    var microphoneWaveform: (() -> [Float])?
    /// The Mac's panel: smaller, side by side with other content.
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mcTuningFrozenTime) private var frozenTime
    /// When each sweep's answer reached this view, to draw its trace in.
    @State private var arrivals: [Int: Date] = [:]

    private var entry: SyncCalibrationStatus.Speaker? {
        guard let status else { return nil }
        if let speaker, let own = status.speaker(speaker.id) { return own }
        return status.current
    }

    private var isListening: Bool { status?.isRunning == true && entry?.outcome == .measuring }

    var body: some View {
        VStack(spacing: compact ? MC.Space.m : MC.Space.l) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isListening || frozenTime != nil)) { timeline in
                let now = timeline.date
                VStack(spacing: compact ? MC.Space.s : MC.Space.m) {
                    scene(now: now)
                        .frame(height: compact ? 96 : 150)
                    scope(now: now)
                        .frame(height: compact ? 84 : 116)
                }
            }
            .accessibilityHidden(true)

            TuningReadout(speaker: speaker, status: status, entry: entry, compact: compact)
        }
        .onChange(of: entry?.sweeps.count ?? 0) { old, new in
            // A fresh tuning starts the record again.
            if new < old { arrivals = [:] }
            if new > 0, arrivals[new - 1] == nil { arrivals[new - 1] = Date() }
        }
        .sensoryFeedback(trigger: entry?.sweeps.count ?? 0) { old, new in
            guard new > old, entry?.sweeps.last?.latenessMs != nil else { return nil }
            return .impact(weight: .light, intensity: 0.6)
        }
        .sensoryFeedback(trigger: entry?.outcome) { _, outcome in
            switch outcome {
            case .aligned: .success
            case .notHeard, .unclear, .skipped: .error
            default: nil
            }
        }
    }

    // MARK: Scene

    /// Seconds since the first sweep left the speaker; nil before it has.
    private func elapsed(_ now: Date) -> TimeInterval? {
        guard let began = entry?.sweepsBeganAt else { return nil }
        if let frozenTime { return frozenTime }
        return now.timeIntervalSince(began)
    }

    private func scene(now: Date) -> some View {
        let outcome = entry?.outcome
        let sweeps = entry?.sweeps ?? []
        let period = max(0.2, status?.sweepPeriod ?? 1)
        let total = max(1, status?.sweepsPerSpeaker ?? 5)
        let t = elapsed(now)
        let listening = isListening
        let moving = listening && !reduceMotion
        let waveform = listening ? microphoneWaveform?() : nil
        let glyph: CGFloat = compact ? 38 : 52

        return GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // Room at both ends for the rings that open around the glyphs.
            let from = CGPoint(x: glyph / 2 + 18, y: h / 2)
            let to = CGPoint(x: w - glyph / 2 - 18, y: h / 2)
            ZStack {
                Canvas { context, _ in
                    let accent = MC.accent
                    let quiet = MC.Ink.faint.resolve(in: context.environment)
                    let good = MC.Status.playing.resolve(in: context.environment)
                    let span = to.x - from.x - glyph

                    // The path the sound takes.
                    var path = Path()
                    path.move(to: CGPoint(x: from.x + glyph / 2 + 6, y: h / 2))
                    path.addLine(to: CGPoint(x: to.x - glyph / 2 - 6, y: h / 2))
                    let settled: Color = outcome?.isAligned == true ? good.opacity(0.7) : quiet
                    context.stroke(path, with: .color(settled), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: outcome?.isAligned == true ? [] : [2, 5]))

                    guard listening else { return }
                    if moving, let t {
                        for n in 0..<total {
                            let age = t - Double(n) * period
                            guard age >= 0 else { continue }
                            let known = sweeps.indices.contains(n)
                            let heard = known && sweeps[n].latenessMs != nil
                            // In the air: three fronts, the first the brightest.
                            if age <= period {
                                let p = age / period
                                for k in 0..<3 {
                                    let pk = p - Double(k) * 0.07
                                    guard pk > 0 else { continue }
                                    let radius = glyph / 2 + 6 + pk * span
                                    // A front opens as it leaves, then stays as tall as the band.
                                    let half = min(55, asin(min(1, (h / 2 - 4) / radius)) * 180 / .pi)
                                    var arc = Path()
                                    arc.addArc(center: from, radius: radius, startAngle: .degrees(-half), endAngle: .degrees(half), clockwise: false)
                                    let fade = pow(1 - pk, 0.5) * (1 - Double(k) * 0.3)
                                    context.stroke(arc, with: .color(accent.opacity(0.85 * fade)),
                                                   style: StrokeStyle(lineWidth: 3 - CGFloat(k) * 0.7, lineCap: .round))
                                }
                            }
                            // Landed: a ring at the microphone, once its answer is in.
                            let since = age - period
                            if known, since >= 0, since <= 0.6 {
                                let p = since / 0.6
                                let ring = Path(ellipseIn: CGRect(x: to.x - glyph / 2, y: to.y - glyph / 2, width: glyph, height: glyph)
                                    .insetBy(dx: -CGFloat(p) * 14, dy: -CGFloat(p) * 14))
                                context.stroke(ring, with: .color((heard ? good : quiet).opacity(1 - p)), lineWidth: 2.5)
                            }
                        }
                    } else {
                        // Reduce Motion: one mark per sweep, filled as it is heard.
                        for n in 0..<total {
                            let x = from.x + glyph / 2 + 6 + span * (CGFloat(n) + 1) / CGFloat(total + 1)
                            let dot = Path(ellipseIn: CGRect(x: x - 4, y: h / 2 - 4, width: 8, height: 8))
                            if sweeps.indices.contains(n) {
                                context.fill(dot, with: .color(sweeps[n].latenessMs != nil ? good : quiet))
                            } else {
                                context.stroke(dot, with: .color(quiet), lineWidth: 1.5)
                            }
                        }
                    }

                    // The room as this microphone hears it right now.
                    if let waveform, waveform.count > 4 {
                        let box = CGRect(x: to.x - 34, y: to.y + glyph / 2 + 8, width: 68, height: 20)
                        let gain = 1 / max(0.02, waveform.map(abs).max() ?? 0.02)
                        var line = Path()
                        for (i, sample) in waveform.enumerated() {
                            let x = box.minX + box.width * CGFloat(i) / CGFloat(waveform.count - 1)
                            let y = box.midY - CGFloat(sample * gain) * box.height / 2
                            if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        context.stroke(line, with: .color(MC.Ink.secondary.resolve(in: context.environment)),
                                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    }
                }

                glyphBadge(speaker?.glyph.symbolName ?? "hifispeaker.fill", size: glyph,
                           lit: sounding(t: t, period: period, total: total, listening: listening))
                    .position(from)
                glyphBadge(microphoneSymbol, size: glyph, lit: false, tint: outcome?.isAligned == true ? MC.Status.playing : nil)
                    .position(to)
            }
        }
    }

    /// Whether a sweep is leaving the speaker at this instant.
    private func sounding(t: TimeInterval?, period: Double, total: Int, listening: Bool) -> Bool {
        guard listening, !reduceMotion, let t, t >= 0, t < Double(total) * period else { return false }
        return t.truncatingRemainder(dividingBy: period) < 0.25
    }

    private var microphoneSymbol: String {
        switch status?.microphone {
        case .phone: "iphone"
        default: "laptopcomputer"
        }
    }

    private func glyphBadge(_ symbol: String, size: CGFloat, lit: Bool, tint: Adaptive? = nil) -> some View {
        ZStack {
            Circle().fill(MC.Surface.well)
            Circle().strokeBorder(lit ? AnyShapeStyle(MC.accent) : AnyShapeStyle(MC.Ink.faint), lineWidth: lit ? 2 : 1)
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(MC.Ink.body))
        }
        .frame(width: size, height: size)
        .animation(MC.Motion.feedback, value: lit)
    }

    // MARK: Scope

    private func scope(now: Date) -> some View {
        let sweeps = entry?.sweeps ?? []
        let earliest = max(1, status?.earliestMs ?? 150), latest = max(1, status?.latestMs ?? 600)
        let outcome = entry?.outcome
        let arrivals = arrivals
        let animate = !reduceMotion && frozenTime == nil

        return Canvas { context, size in
            let ink = MC.Ink.tertiary.resolve(in: context.environment)
            let faint = MC.Ink.faint.resolve(in: context.environment)
            let good = MC.Status.playing.resolve(in: context.environment)
            let accent = MC.accent
            let labels: CGFloat = 18
            let plot = CGRect(x: 0, y: 4, width: size.width, height: size.height - labels - 4)
            func x(_ ms: Double) -> CGFloat { plot.minX + plot.width * CGFloat((ms + earliest) / (earliest + latest)) }

            // The floor, and where a speaker with no delay at all would be heard.
            var floor = Path()
            floor.move(to: CGPoint(x: plot.minX, y: plot.maxY))
            floor.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            context.stroke(floor, with: .color(faint), lineWidth: 1)
            var expected = Path()
            expected.move(to: CGPoint(x: x(0), y: plot.minY))
            expected.addLine(to: CGPoint(x: x(0), y: plot.maxY))
            context.stroke(expected, with: .color(faint), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            let caption = Font.caption2
            context.draw(Text("on time").font(caption).foregroundStyle(ink), at: CGPoint(x: x(0), y: size.height - labels / 2), anchor: .center)
            context.draw(Text("later").font(caption).foregroundStyle(ink), at: CGPoint(x: plot.maxX, y: size.height - labels / 2), anchor: .trailing)

            // Each sweep's search, oldest first so the newest lies on top.
            for (n, sweep) in sweeps.enumerated() {
                let bytes = [UInt8](sweep.trace)
                guard bytes.count > 1 else { continue }
                let heard = sweep.latenessMs != nil
                let newest = n == sweeps.count - 1
                // How tall it stands says how sure the microphone was.
                let height = plot.height * CGFloat(min(1, max(0.25, sweep.strength / 14)))
                var line = Path()
                for (i, byte) in bytes.enumerated() {
                    let px = plot.minX + plot.width * (CGFloat(i) + 0.5) / CGFloat(bytes.count)
                    let py = plot.maxY - height * CGFloat(byte) / 255
                    if i == 0 { line.move(to: CGPoint(x: px, y: py)) } else { line.addLine(to: CGPoint(x: px, y: py)) }
                }
                var reveal: CGFloat = 1
                if animate, newest, let at = arrivals[n] { reveal = CGFloat(min(1, max(0, now.timeIntervalSince(at) / 0.45))) }
                let age = Double(sweeps.count - 1 - n)
                let opacity = newest ? 1 : max(0.16, 0.5 - age * 0.1)
                var layer = context
                layer.clip(to: Path(CGRect(x: plot.minX, y: 0, width: plot.width * reveal, height: size.height)))
                if newest, heard {
                    // The newest search stands on a soft wash of its own colour.
                    var area = line
                    area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                    area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
                    area.closeSubpath()
                    layer.fill(area, with: .linearGradient(Gradient(colors: [accent.opacity(0.28), accent.opacity(0)]),
                                                           startPoint: CGPoint(x: 0, y: plot.maxY - height), endPoint: CGPoint(x: 0, y: plot.maxY)))
                }
                layer.stroke(line, with: .color((heard ? accent : ink).opacity(opacity)),
                             style: StrokeStyle(lineWidth: newest ? 2 : 1.2, lineCap: .round, lineJoin: .round))
                if heard, let lateness = sweep.latenessMs, reveal >= CGFloat((lateness + earliest) / (earliest + latest)) {
                    let peak = CGPoint(x: x(lateness), y: plot.maxY - height)
                    if newest {
                        layer.drawLayer { glow in
                            glow.addFilter(.blur(radius: 5))
                            glow.fill(Path(ellipseIn: CGRect(x: peak.x - 6, y: peak.y - 6, width: 12, height: 12)), with: .color(accent.opacity(0.7)))
                        }
                    }
                    layer.fill(Path(ellipseIn: CGRect(x: peak.x - 3, y: peak.y - 3, width: 6, height: 6)), with: .color(accent.opacity(newest ? 1 : 0.5)))
                }
            }

            // Known: the place the sweeps agreed on.
            if outcome?.isAligned == true {
                let found = sweeps.compactMap(\.latenessMs).sorted()
                if !found.isEmpty {
                    let median = found[found.count / 2]
                    var lock = Path()
                    lock.move(to: CGPoint(x: x(median), y: plot.minY))
                    lock.addLine(to: CGPoint(x: x(median), y: plot.maxY))
                    context.stroke(lock, with: .color(good), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
    }
}

// MARK: - Readout

/// The words under the stage: what is happening, then what was found.
private struct TuningReadout: View {
    var speaker: SpeakerItem?
    var status: SyncCalibrationStatus?
    var entry: SyncCalibrationStatus.Speaker?
    var compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: MC.Space.s) {
            switch presentation {
            case .idle:
                EmptyView()
            case .listening(let title, let detail, let heard, let needed):
                headline(title, symbol: nil)
                HStack(spacing: MC.Space.s) {
                    AgreementDots(heard: heard, needed: needed)
                    Text(detail)
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            case .aligned(let title, let lagMs, let previous, let trim, let note):
                headline(title, symbol: "checkmark.circle.fill", tint: MC.Status.playing)
                if let lagMs {
                    LagSlide(lagMs: lagMs, compact: compact)
                        .padding(.vertical, MC.Space.xs)
                }
                Text(note)
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if previous != trim {
                    HStack(spacing: MC.Space.s) {
                        trimChip("Trim was", previous, strong: false)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MC.Ink.tertiary)
                        trimChip("Now", trim, strong: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sync trim was \(MC.Format.trim(previous)), now \(MC.Format.trim(trim))")
                }
            case .failed(let title, let detail):
                headline(title, symbol: "exclamationmark.triangle.fill", tint: MC.Status.failed)
                Text(detail)
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(MC.Motion.state(reduceMotion), value: entry?.outcome)
        .accessibilityElement(children: .combine)
    }

    private func headline(_ text: String, symbol: String?, tint: Adaptive? = nil) -> some View {
        HStack(spacing: MC.Space.s) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(MC.Ink.body))
                    .symbolEffect(.bounce, options: .nonRepeating, value: entry?.outcome.isFinished == true)
                    .accessibilityHidden(true)
            }
            Text(text)
                .foregroundStyle(MC.Ink.primary)
        }
        .font(compact ? MC.Font.bodyEmphasis : MC.Font.title)
        .transition(.opacity)
    }

    private func trimChip(_ label: String, _ ms: Int, strong: Bool) -> some View {
        HStack(spacing: MC.Space.xs) {
            Text(label).foregroundStyle(MC.Ink.secondary)
            Text(MC.Format.trim(ms))
                .foregroundStyle(strong ? MC.Ink.primary : MC.Ink.secondary)
                .fontWeight(strong ? .semibold : .regular)
                .monospacedDigit()
        }
        .font(MC.Font.caption)
        .padding(.horizontal, MC.Space.s)
        .padding(.vertical, MC.Space.xs)
        .background(MC.Surface.well, in: Capsule())
    }

    private enum Presentation {
        case idle
        case listening(title: String, detail: String, heard: Int, needed: Int)
        case aligned(title: String, lagMs: Double?, previous: Int, trim: Int, note: String)
        case failed(title: String, detail: String)
    }

    private var presentation: Presentation {
        guard let status else { return .idle }
        if !status.isRunning, let problem = status.problem { return .failed(title: "Couldn\u{2019}t tune", detail: problem) }
        guard let entry else { return .idle }
        let name = speaker?.name ?? "This speaker"
        switch entry.outcome {
        case .waiting:
            return .listening(title: "Waiting", detail: "Its turn comes next", heard: 0, needed: 3)
        case .measuring:
            let heard = entry.sweeps.filter { $0.latenessMs != nil }.count
            guard entry.sweepsBeganAt != nil else {
                return .listening(title: "Getting ready\u{2026}", detail: "Connecting to \(name)", heard: 0, needed: 3)
            }
            let total = status.sweepsPerSpeaker
            return .listening(title: "Listening\u{2026}", detail: "Sweep \(min(total, entry.sweeps.count + 1)) of \(total)", heard: heard, needed: 3)
        case .aligned(let lagMs, let trimMs, let reachedLimit, let isReference):
            if isReference {
                return .aligned(title: "Measured", lagMs: nil, previous: entry.previousTrimMs, trim: trimMs,
                                note: "\(name) is what the others line up to. Tune another speaker and it falls into step with this one.")
            }
            let lag = Int(lagMs.rounded())
            let was = lag == 0 ? "It was already in step." : (lag > 0 ? "It was playing \(lag) ms late." : "It was playing \(-lag) ms early.")
            if reachedLimit {
                return .aligned(title: "As close as it goes", lagMs: lagMs, previous: entry.previousTrimMs, trim: trimMs,
                                note: "\(was) That is more than the trim can take up, so it is set as far as it goes.")
            }
            return .aligned(title: "In sync", lagMs: lagMs, previous: entry.previousTrimMs, trim: trimMs, note: "\(was) Saved on the Mac for this speaker.")
        case .notHeard, .unclear, .skipped:
            return .failed(title: entry.outcome.caption, detail: entry.outcome.nextStep(microphone: status.microphone) ?? "")
        }
    }
}

/// Three marks: how many sweeps have been heard of the three that must agree.
private struct AgreementDots: View {
    var heard: Int
    var needed: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: MC.Space.xs) {
            ForEach(0..<needed, id: \.self) { i in
                Circle()
                    .fill(i < heard ? AnyShapeStyle(MC.accent) : AnyShapeStyle(MC.Ink.faint))
                    .frame(width: 7, height: 7)
            }
        }
        .animation(MC.Motion.state(reduceMotion), value: heard)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(min(heard, needed)) of \(needed) sweeps heard")
    }
}

/// Before and after on one line: where the speaker was against the others, and the mark
/// sliding into step. Reduce Motion shows both ends at once.
private struct LagSlide: View {
    var lagMs: Double
    var compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mcTuningFrozenTime) private var frozenTime
    @State private var settled = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, mid = w / 2
            // 300 ms spans half the line; further out is pinned to the end.
            let reach = max(-1, min(1, lagMs / 300)) * (mid - 18)
            let isOut = abs(lagMs) >= 0.5
            ZStack {
                Capsule().fill(MC.Ink.faint).frame(height: 2)
                // The others.
                Capsule().fill(MC.Ink.tertiary).frame(width: 2, height: 26).position(x: mid, y: 20)
                // Where it was.
                if isOut {
                    Capsule().fill(MC.Ink.faint).frame(width: 4, height: 18).position(x: mid + reach, y: 20)
                    Text("\(Int(abs(lagMs).rounded())) ms")
                        .font(MC.Font.captionValue)
                        .foregroundStyle(MC.Ink.secondary)
                        .position(x: min(w - 28, max(28, mid + reach)), y: 44)
                }
                // Where it is now.
                Capsule().fill(MC.Status.playing).frame(width: 4, height: 26)
                    .position(x: mid + (settled ? 0 : reach), y: 20)
            }
        }
        .frame(height: 54)
        .frame(maxWidth: compact ? 280 : 320)
        .onAppear {
            if reduceMotion || frozenTime != nil {
                settled = true
            } else {
                withAnimation(MC.Motion.arrive(false).delay(0.35)) { settled = true }
            }
        }
        .accessibilityHidden(true)
    }
}

/// What a list says about a speaker's tuning.
enum TuningWording {
    /// "Tuned today · trim −172 ms", "Not tuned".
    static func state(of speaker: SpeakerItem, now: Date = Date()) -> String {
        guard let at = speaker.tunedAt else {
            return speaker.syncTrimMs == 0 ? "Not tuned" : "Not tuned \u{00B7} trim \(MC.Format.trim(speaker.syncTrimMs)) set by hand"
        }
        let calendar = Calendar.current
        let when: String
        if calendar.isDate(at, inSameDayAs: now) {
            when = "today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(at, inSameDayAs: yesterday) {
            when = "yesterday"
        } else {
            when = at.formatted(.dateTime.day().month(.abbreviated))
        }
        return "Tuned \(when) \u{00B7} trim \(MC.Format.trim(speaker.syncTrimMs))"
    }
}
