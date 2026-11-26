import MulticastAudio

/// Pure pacing arithmetic, separated from the thread so it can be tested with a simulated clock.
///
/// Packet emission deadline = `timeline.playoutHostNanos(forFrame:) - timeline.latencyNanos`.
/// Every deadline is derived from the frame index against the timeline anchor, so rounding
/// never accumulates (no drift), and after a stall the schedule simply finds itself behind:
/// it emits back-to-back up to `maxBurst` packets, then takes a short breather, until caught up.
/// When it is so far behind that a packet could no longer reach a speaker `minDeliveryLead`
/// before it is due, it skips whole packets forward to the one due now.
struct PacingSchedule: Sendable {
    enum Step: Equatable {
        /// Nothing due: sleep until this host time.
        case sleep(untilNanos: UInt64)
        /// Emit the packet starting at `frame`; it was due at `deadline`.
        case emit(frame: UInt64, deadline: UInt64)
        /// Too far behind: `count` packets were dropped; `nextFrame` jumped forward.
        case skip(count: UInt64)
    }

    let timeline: StreamTimeline
    private(set) var nextFrame: UInt64
    let maxBurst: Int
    let skipLagNanos: UInt64
    let breatherNanos: UInt64

    static let packetFrames = UInt64(PCM.framesPerPacket)
    static let packetNanos = PCM.nanos(forFrames: UInt64(PCM.framesPerPacket))

    init(timeline: StreamTimeline, startFrame: UInt64, maxBurst: Int, minDeliveryLeadNanos: UInt64) {
        precondition(startFrame >= timeline.anchorFrame, "pacing must start at or after the anchor")
        precondition((startFrame - timeline.anchorFrame) % Self.packetFrames == 0, "start frame must be packet aligned")
        self.timeline = timeline
        self.nextFrame = startFrame
        self.maxBurst = max(1, maxBurst)
        let latency = timeline.latencyNanos
        // A packet that is later than this would reach the speaker less than minDeliveryLead before playout.
        if latency > minDeliveryLeadNanos * 2 {
            skipLagNanos = latency - minDeliveryLeadNanos
        } else {
            skipLagNanos = max(latency / 2, Self.packetNanos * 4)
        }
        breatherNanos = Self.packetNanos / 4
    }

    /// Host time the packet starting at `frame` should be handed to sinks.
    func deadline(forFrame frame: UInt64) -> UInt64 {
        // Full-width math: the contract helper traps ~4.84 days after the anchor.
        let playout = TimelineMath.playoutHostNanos(timeline, forFrame: frame)
        return playout > timeline.latencyNanos ? playout - timeline.latencyNanos : 0
    }

    /// Decide what to do at host time `now`, given how many packets were emitted since the last sleep.
    mutating func step(now: UInt64, burstSoFar: Int) -> Step {
        let due = deadline(forFrame: nextFrame)
        if now < due {
            return .sleep(untilNanos: due)
        }
        if now - due > skipLagNanos {
            // Jump to the packet that is due right now (deadline <= now, floor arithmetic).
            let base = deadline(forFrame: timeline.anchorFrame)
            let packetsSinceAnchor = TimelineMath.frames(forNanos: now - base) / Self.packetFrames
            let target = timeline.anchorFrame + packetsSinceAnchor * Self.packetFrames
            if target > nextFrame {
                let count = (target - nextFrame) / Self.packetFrames
                nextFrame = target
                return .skip(count: count)
            }
        }
        if burstSoFar >= maxBurst {
            return .sleep(untilNanos: now + breatherNanos)
        }
        let frame = nextFrame
        nextFrame += Self.packetFrames
        return .emit(frame: frame, deadline: due)
    }
}
