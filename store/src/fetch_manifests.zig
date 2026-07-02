//! Concurrent "fetch every registry entry's manifest_url and validate it" — the network-bound
//! step shared by `store ingest` (which then upserts the results into `registry.db`) and
//! `store validate` (which only needs to know ok/warn counts for the PR gate, never touching a
//! database). Kept separate from both so neither has to duplicate the threading.
const std = @import("std");

const registry_entry = @import("registry_entry.zig");
const manifest_mod = @import("manifest.zig");
const fetch = @import("fetch.zig");

/// Simultaneous manifest fetches. Bounded so a run against ~1000 plugins is polite to whatever
/// hosts (GitHub Pages, release assets, etc.) are serving their manifests, rather than opening a
/// thousand connections at once.
const max_concurrency = 32;

pub const ErrMsg = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    fn set(self: *ErrMsg, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch {
            self.len = 0;
            return;
        };
        self.len = s.len;
    }

    pub fn slice(self: *const ErrMsg) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Outcome = union(enum) {
    ok: std.json.Parsed(manifest_mod.Manifest),
    err: ErrMsg,
};

const Job = struct {
    entries: []const registry_entry.LoadedEntry,
    outcomes: []Outcome,
    next_index: std.atomic.Value(usize) = .init(0),
    allocator: std.mem.Allocator,
    io: std.Io,

    fn worker(job: *Job) void {
        while (true) {
            const i = job.next_index.fetchAdd(1, .monotonic);
            if (i >= job.entries.len) return;
            job.outcomes[i] = fetchAndValidate(job.allocator, job.io, job.entries[i].value());
        }
    }
};

fn fetchAndValidate(allocator: std.mem.Allocator, io: std.Io, entry: registry_entry.RegistryEntry) Outcome {
    const bytes = fetch.fetchBytes(allocator, io, entry.manifest_url) catch |err| {
        var msg: ErrMsg = .{};
        msg.set("fetch failed: {s}", .{@errorName(err)});
        return .{ .err = msg };
    };
    defer allocator.free(bytes);

    const parsed = manifest_mod.parseAndValidate(allocator, bytes, entry.id) catch |err| {
        var msg: ErrMsg = .{};
        msg.set("invalid manifest: {s}", .{@errorName(err)});
        return .{ .err = msg };
    };
    return .{ .ok = parsed };
}

/// Fetch + validate every entry's manifest concurrently. Returns one `Outcome` per entry,
/// index-aligned with `entries`. Caller owns the returned slice and must `deinit()` each `.ok`
/// payload (see `freeAll` for the common case of doing both together).
pub fn fetchAll(allocator: std.mem.Allocator, io: std.Io, entries: []const registry_entry.LoadedEntry) ![]Outcome {
    const outcomes = try allocator.alloc(Outcome, entries.len);
    errdefer allocator.free(outcomes);

    var job: Job = .{ .entries = entries, .outcomes = outcomes, .allocator = allocator, .io = io };
    const worker_count = @min(entries.len, max_concurrency);
    if (worker_count == 0) return outcomes;

    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, Job.worker, .{&job});
    for (threads) |t| t.join();

    return outcomes;
}

/// Free every `.ok` payload's arena and the outcomes slice itself.
pub fn freeAll(allocator: std.mem.Allocator, outcomes: []Outcome) void {
    for (outcomes) |*outcome| switch (outcome.*) {
        .ok => |*parsed| parsed.deinit(),
        .err => {},
    };
    allocator.free(outcomes);
}
