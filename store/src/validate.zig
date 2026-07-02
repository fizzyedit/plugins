//! `store validate`: the PR-time gate `validate.yml` runs — every `registry/<id>.json` must be
//! structurally valid (bad JSON, a missing required key, or id != filename stem fails the run
//! immediately, same as `registry_entry.loadAll`), and every manifest is fetched + validated
//! best-effort: an unreachable or malformed manifest is only ever a warning here, never a
//! failure, because manifest hosting is the *author's* infrastructure and flaky/down for a
//! moment is not a reason to block an unrelated registry PR. Mirrors `aggregate.py --check`.
//!
//! Deliberately does not open `registry.db` — this only needs to run inside a reviewed PR's CI
//! job, with no persistent state and no side effects.
const std = @import("std");

const registry_entry = @import("registry_entry.zig");
const fetch_manifests = @import("fetch_manifests.zig");

const Options = struct {
    root: []const u8 = "..",
};

fn parseArgs(args: []const []const u8) Options {
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--root") and i + 1 < args.len) {
            i += 1;
            opts.root = args[i];
        }
    }
    return opts;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    const opts = parseArgs(args);

    const registry_dir = try std.fs.path.join(allocator, &.{ opts.root, "registry" });
    defer allocator.free(registry_dir);

    // A malformed registry/<id>.json propagates as an error here (registry_entry.loadAll already
    // logged specifics) — that's the hard-fail half of this gate.
    const entries = try registry_entry.loadAll(allocator, io, registry_dir);
    defer {
        for (entries) |*e| e.deinit();
        allocator.free(entries);
    }

    std.debug.print("validate: {d} registry entr{s} structurally ok\n", .{
        entries.len,
        if (entries.len == 1) "y is" else "ies are",
    });
    if (entries.len == 0) return;

    const outcomes = try fetch_manifests.fetchAll(allocator, io, entries);
    defer fetch_manifests.freeAll(allocator, outcomes);

    var ok_count: usize = 0;
    var warn_count: usize = 0;
    for (entries, outcomes) |loaded, outcome| {
        const entry = loaded.value();
        switch (outcome) {
            .ok => |parsed| {
                std.debug.print("  ok    {s}: {d} release(s)\n", .{ entry.id, parsed.value.releases.len });
                ok_count += 1;
            },
            .err => |msg| {
                std.debug.print("  warn  {s}: {s} (manifest hosting is the author's — not a gate failure)\n", .{ entry.id, msg.slice() });
                warn_count += 1;
            },
        }
    }

    std.debug.print("validate done: {d} manifest(s) reachable, {d} warning(s)\n", .{ ok_count, warn_count });
}
