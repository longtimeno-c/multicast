import Foundation
import os

// Pure helpers for hub clients (the apps' HubModel) and backends. No UI, no I/O.

// MARK: - PagedList

/// A list being loaded page by page, client side. Tracks the cursor for the next page and which
/// content revision the loaded pages belong to, so a late page from before a reset is dropped
/// instead of mixed into the new list.
public struct PagedList<Item: Identifiable & Sendable & Codable & Equatable>: Equatable, Sendable {
    public private(set) var items: [Item] = []
    /// Cursor for the next page; meaningful once the first page arrived.
    public private(set) var nextCursor: String?
    /// The first page arrived (so an empty `items` really means an empty list).
    public private(set) var isLoaded = false
    /// The content revision the loaded pages belong to.
    public private(set) var revision: UInt64
    public private(set) var totalCount: Int?

    public init(revision: UInt64 = 0) { self.revision = revision }

    /// Already filled, for snapshots and previews.
    public init(items: [Item], revision: UInt64 = 0) {
        self.items = items
        self.revision = revision
        self.isLoaded = true
        self.totalCount = items.count
    }

    /// More pages exist (or the first one has not been fetched yet).
    public var canLoadMore: Bool { !isLoaded || nextCursor != nil }

    /// The request for the next page, or nil when the list is complete.
    public func nextRequest(limit: Int = PageRequest.defaultLimit) -> PageRequest? {
        guard canLoadMore else { return nil }
        return PageRequest(cursor: isLoaded ? nextCursor : nil, limit: limit)
    }

    // Optimistic edits (a UI changes Up Next before the hub's next page arrives).

    public mutating func removeAll(ids: Set<Item.ID>) {
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        if let t = totalCount { totalCount = max(0, t - (before - items.count)) }
    }

    /// Drops every item up to and including `id`.
    public mutating func removeThrough(_ id: Item.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items.removeFirst(i + 1)
        if let t = totalCount { totalCount = max(0, t - (i + 1)) }
    }

    /// SwiftUI `onMove` semantics.
    public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.sorted().filter { items.indices.contains($0) }.map { items[$0] }
        guard !moving.isEmpty else { return }
        let target = min(max(0, destination), items.count)
        let before = offsets.filter { $0 < target }.count
        for i in offsets.sorted(by: >) where items.indices.contains(i) { items.remove(at: i) }
        items.insert(contentsOf: moving, at: target - before)
    }

    /// The list changed on the backend: forget the pages and start again at `revision`.
    /// Items stay visible until the new first page replaces them, so the list doesn't blink.
    public mutating func invalidate(revision: UInt64) {
        guard revision != self.revision || !isLoaded else { return }
        self.revision = revision
        isLoaded = false
        nextCursor = nil
    }

    /// Takes a page fetched with `request` for `revision`. Returns false (and changes nothing)
    /// when the page is stale: from another revision, or not the page that comes next.
    @discardableResult
    public mutating func receive(_ page: Page<Item>, for request: PageRequest, revision: UInt64) -> Bool {
        guard revision == self.revision else { return false }
        if request.cursor == nil {
            items = page.items
        } else {
            guard isLoaded, request.cursor == nextCursor else { return false }
            // A list that shifted between pages may repeat an item at the seam; keep the first.
            let seen = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !seen.contains($0.id) })
        }
        isLoaded = true
        nextCursor = page.nextCursor
        totalCount = page.totalCount
        return true
    }

    /// Whether `item` is close enough to the end that the next page should be fetched.
    public func shouldLoadMore(after itemID: Item.ID, threshold: Int = 20) -> Bool {
        guard nextCursor != nil, isLoaded else { return false }
        guard let i = items.lastIndex(where: { $0.id == itemID }) else { return false }
        return i >= items.count - threshold
    }
}

// MARK: - ArtworkCache

/// Least-recently-used cache of encoded artwork, bounded by total bytes. Keyed by artwork id and
/// the pixel size asked for, since a backend may scale on request.
public struct ArtworkCache: Sendable {
    public struct Key: Hashable, Sendable {
        public var id: ArtworkID
        public var maxPixel: Int
        public init(id: ArtworkID, maxPixel: Int) { self.id = id; self.maxPixel = maxPixel }
    }

    public let byteLimit: Int
    public private(set) var totalBytes = 0
    private var entries: [Key: (data: Data, tick: UInt64)] = [:]
    private var tick: UInt64 = 0

    public init(byteLimit: Int = 32 << 20) { self.byteLimit = byteLimit }

    public var count: Int { entries.count }

    /// The bytes for `key`, marking them recently used.
    public mutating func data(for key: Key) -> Data? {
        guard let hit = entries[key] else { return nil }
        tick += 1
        entries[key] = (hit.data, tick)
        return hit.data
    }

    /// The bytes for `key` without touching recency (safe to call from a view body).
    public func peek(_ key: Key) -> Data? { entries[key]?.data }

    public mutating func insert(_ data: Data, for key: Key) {
        if let old = entries[key] { totalBytes -= old.data.count }
        tick += 1
        entries[key] = (data, tick)
        totalBytes += data.count
        evict()
    }

    private mutating func evict() {
        guard totalBytes > byteLimit else { return }
        // Oldest first; the newest entry always stays, even if alone it is over the limit.
        for (key, value) in entries.sorted(by: { $0.value.tick < $1.value.tick }) {
            guard totalBytes > byteLimit, entries.count > 1 else { break }
            entries[key] = nil
            totalBytes -= value.data.count
        }
    }
}

// MARK: - HubStateBroadcaster

/// Holds a backend's `HubState` and fans it out to any number of `states()` subscribers: each
/// gets the current state at once, then every change, newest only. `update` bumps `revision`
/// only when something else changed, so a no-op update sends nothing. Thread-safe.
public final class HubStateBroadcaster: @unchecked Sendable {
    private struct Inner {
        var state: HubState
        var subscribers: [UUID: AsyncStream<HubState>.Continuation] = [:]
        var finished = false
    }

    private let inner: OSAllocatedUnfairLock<Inner>

    public init(_ initial: HubState = HubState()) {
        inner = OSAllocatedUnfairLock(uncheckedState: Inner(state: initial))
    }

    public var state: HubState { inner.withLockUnchecked { $0.state } }

    /// A new subscription: yields the current state at once.
    public func stream() -> AsyncStream<HubState> {
        let (stream, continuation) = AsyncStream.makeStream(of: HubState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.inner.withLockUnchecked { _ = $0.subscribers.removeValue(forKey: id) }
        }
        let finished: Bool = inner.withLockUnchecked {
            continuation.yield($0.state)
            if !$0.finished { $0.subscribers[id] = continuation }
            return $0.finished
        }
        if finished { continuation.finish() }
        return stream
    }

    /// Applies `change`; if anything but the revision changed, bumps the revision and publishes.
    /// Returns the state after the change.
    @discardableResult
    public func update(_ change: (inout HubState) -> Void) -> HubState {
        // Yields happen under the lock so concurrent updates reach every subscriber in revision
        // order (a yield never runs subscriber code; `finish`, which can, stays outside).
        inner.withLockUnchecked {
            var next = $0.state
            change(&next)
            next.revision = $0.state.revision
            guard !next.hasSameContent(as: $0.state) else { return $0.state }
            next.revision = $0.state.revision &+ 1
            $0.state = next
            for c in $0.subscribers.values { c.yield(next) }
            return next
        }
    }

    /// Ends every subscription (and any made later).
    public func finish() {
        let targets: [AsyncStream<HubState>.Continuation] = inner.withLockUnchecked {
            $0.finished = true
            let all = Array($0.subscribers.values)
            $0.subscribers.removeAll()
            return all
        }
        for c in targets { c.finish() }
    }

    public var subscriberCount: Int { inner.withLockUnchecked { $0.subscribers.count } }
}
