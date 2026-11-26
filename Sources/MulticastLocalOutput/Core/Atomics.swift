import Foundation
import Synchronization

/// A 64-bit atomic cell usable on the deployment floor (macOS 14 / iOS 17).
///
/// On macOS 15+ / iOS 18+ (every machine this project actually runs on) it is a real lock-free
/// `Synchronization.Atomic<UInt64>` living in manually allocated, stable memory. On older OSes,
/// where `Atomic` is unavailable, it falls back to an `os_unfair_lock`-protected word: the lock
/// is held for a single load/store, never across work, so it is never meaningfully contended.
final class AtomicU64: @unchecked Sendable {
    private let raw: UnsafeMutableRawPointer
    private let fallbackLock: UnsafeMutablePointer<os_unfair_lock>

    init(_ value: UInt64 = 0) {
        raw = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        fallbackLock = .allocate(capacity: 1)
        fallbackLock.initialize(to: os_unfair_lock())
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
            raw.bindMemory(to: Atomic<UInt64>.self, capacity: 1).initialize(to: Atomic(value))
        } else {
            raw.bindMemory(to: UInt64.self, capacity: 1).initialize(to: value)
        }
    }

    deinit {
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
            _ = raw.assumingMemoryBound(to: Atomic<UInt64>.self).deinitialize(count: 1)
        }
        raw.deallocate()
        fallbackLock.deinitialize(count: 1)
        fallbackLock.deallocate()
    }

    @inline(__always)
    func load(acquire: Bool = true) -> UInt64 {
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
            let p = raw.assumingMemoryBound(to: Atomic<UInt64>.self)
            return acquire ? p.pointee.load(ordering: .acquiring) : p.pointee.load(ordering: .relaxed)
        } else {
            os_unfair_lock_lock(fallbackLock)
            let v = raw.assumingMemoryBound(to: UInt64.self).pointee
            os_unfair_lock_unlock(fallbackLock)
            return v
        }
    }

    @inline(__always)
    func store(_ value: UInt64, release: Bool = true) {
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
            let p = raw.assumingMemoryBound(to: Atomic<UInt64>.self)
            if release { p.pointee.store(value, ordering: .releasing) } else { p.pointee.store(value, ordering: .relaxed) }
        } else {
            os_unfair_lock_lock(fallbackLock)
            raw.assumingMemoryBound(to: UInt64.self).pointee = value
            os_unfair_lock_unlock(fallbackLock)
        }
    }

    /// Atomically adds `delta` (wrapping) and returns the new value.
    @inline(__always)
    @discardableResult
    func add(_ delta: UInt64) -> UInt64 {
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
            let p = raw.assumingMemoryBound(to: Atomic<UInt64>.self)
            return p.pointee.wrappingAdd(delta, ordering: .acquiringAndReleasing).newValue
        } else {
            os_unfair_lock_lock(fallbackLock)
            let p = raw.assumingMemoryBound(to: UInt64.self)
            p.pointee &+= delta
            let v = p.pointee
            os_unfair_lock_unlock(fallbackLock)
            return v
        }
    }

    // Typed conveniences (bit patterns).
    @inline(__always) func loadInt64() -> Int64 { Int64(bitPattern: load()) }
    @inline(__always) func store(int64 v: Int64) { store(UInt64(bitPattern: v)) }
    @inline(__always) func loadDouble() -> Double { Double(bitPattern: load()) }
    @inline(__always) func store(double v: Double, release: Bool = true) { store(v.bitPattern, release: release) }
}

/// Memory fences matching `AtomicU64`. No-ops on the lock fallback (each lock op orders itself).
@inline(__always)
func fenceRelease() {
    if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) { atomicMemoryFence(ordering: .releasing) }
}

@inline(__always)
func fenceAcquire() {
    if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) { atomicMemoryFence(ordering: .acquiring) }
}
