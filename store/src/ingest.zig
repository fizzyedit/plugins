//! `store ingest`: load `registry/<id>.json`, concurrently fetch every author's `manifest_url`,
//! and upsert into `registry.db`. Replaces `scripts/aggregate.py`'s fetch+validate pass.
//!
//! Resilience is a property of the upsert, not special-cased bookkeeping: a plugin whose fetch
//! or manifest validation fails simply isn't touched this run, so whatever the database already
//! holds (its last successful ingest) stays authoritative — last-known-good falls out of "don't
//! write on failure" rather than needing to diff against a previously generated file.
const std = @import("std");

const db_mod = @import("db.zig");
const registry_entry = @import("registry_entry.zig");
const manifest_mod = @import("manifest.zig");
const time_fmt = @import("time_fmt.zig");
const fetch_manifests = @import("fetch_manifests.zig");

const Options = struct {
    /// Directory containing `registry/`. Defaults to the plugins repo root, assuming this binary
    /// runs from `store/` (its own directory) — matches the intended CI invocation.
    root: []const u8 = "..",
    db_path: []const u8 = "registry.db",
};

fn parseArgs(args: []const []const u8) Options {
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--root") and i + 1 < args.len) {
            i += 1;
            opts.root = args[i];
        } else if (std.mem.eql(u8, args[i], "--db") and i + 1 < args.len) {
            i += 1;
            opts.db_path = args[i];
        }
    }
    return opts;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    const opts = parseArgs(args);

    const registry_dir = try std.fs.path.join(allocator, &.{ opts.root, "registry" });
    defer allocator.free(registry_dir);

    const entries = try registry_entry.loadAll(allocator, io, registry_dir);
    defer {
        for (entries) |*e| e.deinit();
        allocator.free(entries);
    }
    if (entries.len == 0) {
        std.debug.print("ingest: no registry entries found under {s}\n", .{registry_dir});
        return;
    }

    const outcomes = try fetch_manifests.fetchAll(allocator, io, entries);
    defer fetch_manifests.freeAll(allocator, outcomes);

    const db_path_z = try allocator.dupeZ(u8, opts.db_path);
    defer allocator.free(db_path_z);
    var database = try db_mod.open(db_path_z);
    defer database.deinit();

    const today = try time_fmt.todayIso(allocator, io);
    defer allocator.free(today);

    var ok_count: usize = 0;
    var warn_count: usize = 0;
    var skip_count: usize = 0;

    for (entries, outcomes) |loaded, outcome| {
        const entry = loaded.value();
        switch (outcome) {
            .ok => |parsed| {
                try upsertPlugin(&database, entry, today);
                try upsertTags(&database, entry);
                try upsertReleases(&database, entry.id, parsed.value.releases);
                std.debug.print("  ok    {s}: {d} release(s)\n", .{ entry.id, parsed.value.releases.len });
                ok_count += 1;
            },
            .err => |msg| {
                const already_known = try markLastError(&database, entry.id, msg.slice());
                if (already_known) {
                    std.debug.print("  warn  {s}: {s} — kept last-known-good\n", .{ entry.id, msg.slice() });
                    warn_count += 1;
                } else {
                    std.debug.print("  skip  {s}: {s} — no prior entry to fall back on\n", .{ entry.id, msg.slice() });
                    skip_count += 1;
                }
            },
        }
    }

    std.debug.print("ingest done: {d} ok, {d} warn (kept last-known-good), {d} skip\n", .{ ok_count, warn_count, skip_count });
}

fn upsertPlugin(database: *db_mod.Db, entry: registry_entry.RegistryEntry, today: []const u8) !void {
    try database.exec(
        \\INSERT INTO plugins (id, name, description, author, homepage, manifest_url, date_added, last_ok_at, last_error)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
        \\ON CONFLICT(id) DO UPDATE SET
        \\  name = excluded.name,
        \\  description = excluded.description,
        \\  author = excluded.author,
        \\  homepage = excluded.homepage,
        \\  manifest_url = excluded.manifest_url,
        \\  last_ok_at = excluded.last_ok_at,
        \\  last_error = NULL
    ,
        .{},
        .{
            entry.id,          entry.name,     entry.description, entry.author,
            entry.homepage,    entry.manifest_url, today,          today,
        },
    );
}

fn upsertTags(database: *db_mod.Db, entry: registry_entry.RegistryEntry) !void {
    try database.exec("DELETE FROM plugin_tags WHERE plugin_id = ?", .{}, .{entry.id});
    for (entry.tags) |tag| {
        try database.exec(
            "INSERT OR IGNORE INTO plugin_tags (plugin_id, tag) VALUES (?, ?)",
            .{},
            .{ entry.id, tag },
        );
    }
}

/// Upsert every release + its downloads. Never deletes an existing release/download row that the
/// current manifest happens to omit — the database is the durable history an author's own
/// manifest isn't required to retain (see module doc and PLAN.md).
fn upsertReleases(database: *db_mod.Db, plugin_id: []const u8, releases: []const manifest_mod.Release) !void {
    for (releases) |release| {
        // Canonicalize before storing: the fingerprint becomes a shard *directory name* on
        // export, and the Fizzy client builds its shard URL from its own numeric fingerprint as
        // `0x{x}` (lowercase, no leading zeros). An author manifest is free to write
        // "0x0146…" / uppercase hex — numerically identical, but a different string — so
        // normalizing here is what makes the client's URL and the exported path agree.
        var fp_buf: [2 + 16]u8 = undefined;
        const fingerprint = canonicalFingerprint(&fp_buf, release.abi_fingerprint);

        try database.exec(
            \\INSERT INTO releases (plugin_id, version, abi_fingerprint, min_sdk_version, fizzy_sdk_version, published)
            \\VALUES (?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(plugin_id, version, abi_fingerprint) DO UPDATE SET
            \\  min_sdk_version = excluded.min_sdk_version,
            \\  fizzy_sdk_version = excluded.fizzy_sdk_version,
            \\  published = excluded.published
        ,
            .{},
            .{ plugin_id, release.version, fingerprint, release.min_sdk_version, release.fizzy_sdk_version, release.published },
        );

        var it = release.downloads.map.iterator();
        while (it.next()) |kv| {
            try database.exec(
                \\INSERT INTO downloads (plugin_id, version, abi_fingerprint, os_arch, url, sha256)
                \\VALUES (?, ?, ?, ?, ?, ?)
                \\ON CONFLICT(plugin_id, version, abi_fingerprint, os_arch) DO UPDATE SET
                \\  url = excluded.url,
                \\  sha256 = excluded.sha256
            ,
                .{},
                .{ plugin_id, release.version, fingerprint, kv.key_ptr.*, kv.value_ptr.url, kv.value_ptr.sha256 },
            );
        }
    }
}

/// `"0x0146EAF7…"` → `"0x146eaf7…"`: parse as an integer (0x-prefixed, bare hex, or decimal) and
/// reformat as lowercase `0x{x}`, matching how the Fizzy client prints its own
/// `dylib.abi_fingerprint` into the shard URL. Returned slice points into `buf`. A string that
/// doesn't parse is returned as-is — it can never match a real host anyway, and dropping it
/// silently would hide the author's typo.
fn canonicalFingerprint(buf: *[18]u8, s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const value = std.fmt.parseInt(u64, trimmed, 0) catch return s;
    return std.fmt.bufPrint(buf, "0x{x}", .{value}) catch unreachable; // 18 bytes always fits 0x + 16 hex digits
}

test "canonicalFingerprint strips leading zeros and lowercases" {
    var buf: [18]u8 = undefined;
    try std.testing.expectEqualStrings("0x146eaf7c2f9605a", canonicalFingerprint(&buf, "0x0146EAF7C2F9605A"));
    try std.testing.expectEqualStrings("0x98fcfe4f79edb50d", canonicalFingerprint(&buf, "0x98fcfe4f79edb50d"));
    try std.testing.expectEqualStrings("not-a-fingerprint", canonicalFingerprint(&buf, "not-a-fingerprint"));
}

/// Record a fetch/validation failure without touching anything else. Returns whether the plugin
/// already existed (a real "kept last-known-good" case) versus never having been ingested (a
/// pure skip — there's nothing to fall back on).
fn markLastError(database: *db_mod.Db, plugin_id: []const u8, message: []const u8) !bool {
    try database.exec(
        "UPDATE plugins SET last_error = ? WHERE id = ?",
        .{},
        .{ message, plugin_id },
    );
    return database.rowsAffected() > 0;
}
