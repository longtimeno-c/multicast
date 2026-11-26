import Darwin

// The package targets macOS 14 / iOS 17, where `Synchronization.Atomic` is unavailable
// (macOS 15 / iOS 18). Darwin's OSAtomic barrier functions are lock-free, never allocate and
// are safe on real-time threads; they are deprecated only in favour of C11 <stdatomic.h>,
// which Swift cannot import. The protocol indirection below keeps the deprecation warning out
// of the build (a deprecated witness called through a protocol does not warn) without changing
// what is executed: everything is specialised and inlined.

protocol _AtomicPrimitives {
    static func add(_ delta: Int64, _ pointer: UnsafeMutablePointer<Int64>) -> Int64
    static func compareAndSwap(_ old: Int64, _ new: Int64, _ pointer: UnsafeMutablePointer<Int64>) -> Bool
}

enum _DarwinAtomics: _AtomicPrimitives {
    @available(*, deprecated)
    @inline(__always)
    static func add(_ delta: Int64, _ pointer: UnsafeMutablePointer<Int64>) -> Int64 {
        OSAtomicAdd64Barrier(delta, pointer)
    }

    @available(*, deprecated)
    @inline(__always)
    static func compareAndSwap(_ old: Int64, _ new: Int64, _ pointer: UnsafeMutablePointer<Int64>) -> Bool {
        OSAtomicCompareAndSwap64Barrier(old, new, pointer)
    }
}

@inline(__always)
private func _atomicAdd<P: _AtomicPrimitives>(_: P.Type, _ delta: Int64, _ pointer: UnsafeMutablePointer<Int64>) -> Int64 {
    P.add(delta, pointer)
}

@inline(__always)
private func _atomicCAS<P: _AtomicPrimitives>(_: P.Type, _ old: Int64, _ new: Int64, _ pointer: UnsafeMutablePointer<Int64>) -> Bool {
    P.compareAndSwap(old, new, pointer)
}

/// A heap-allocated 64-bit integer with full-barrier (sequentially consistent) atomic access.
/// Lock-free and allocation-free after init: safe to use from real-time threads.
final class AtomicInt64: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Int64>

    init(_ value: Int64 = 0) {
        storage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        storage.initialize(to: value)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    @inline(__always)
    func load() -> Int64 {
        _atomicAdd(_DarwinAtomics.self, 0, storage)
    }

    @inline(__always)
    func store(_ value: Int64) {
        while true {
            let old = load()
            if _atomicCAS(_DarwinAtomics.self, old, value, storage) { return }
        }
    }

    /// Adds `delta` and returns the NEW value.
    @discardableResult
    @inline(__always)
    func add(_ delta: Int64) -> Int64 {
        _atomicAdd(_DarwinAtomics.self, delta, storage)
    }

    @inline(__always)
    func compareAndSwap(expected: Int64, desired: Int64) -> Bool {
        _atomicCAS(_DarwinAtomics.self, expected, desired, storage)
    }

    /// Stores `value` if it is greater than the current value. Returns the resulting value.
    @discardableResult
    @inline(__always)
    func storeMax(_ value: Int64) -> Int64 {
        while true {
            let old = load()
            if value <= old { return old }
            if _atomicCAS(_DarwinAtomics.self, old, value, storage) { return value }
        }
    }
}

/// Atomic boolean built on `AtomicInt64`.
final class AtomicBool: @unchecked Sendable {
    private let value: AtomicInt64
    init(_ initial: Bool = false) { value = AtomicInt64(initial ? 1 : 0) }
    @inline(__always) func load() -> Bool { value.load() != 0 }
    @inline(__always) func store(_ newValue: Bool) { value.store(newValue ? 1 : 0) }
    /// Sets to `false` and returns whether it was `true`.
    @inline(__always) func exchangeFalse() -> Bool {
        while true {
            let old = value.load()
            if old == 0 { return false }
            if value.compareAndSwap(expected: old, desired: 0) { return true }
        }
    }
}
