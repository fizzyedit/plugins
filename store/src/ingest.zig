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
                var changed = try upsertPlugin(&database, entry, parsed.value, today);
                changed = try upsertTags(allocator, &database, entry, parsed.value) or changed;
                changed = try upsertReleases(&database, entry.id, parsed.value.releases) or changed;
                if (changed) try touchLastOk(&database, entry.id, today);
                std.debug.print("  ok    {s}: {d} release(s){s}\n", .{
                    entry.id,
                    parsed.value.releases.len,
                    if (changed) "" else " — unchanged",
                });
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

/// `registry/<id>.json`'s own `description` wins when set (it's reviewed via PR and can be
/// edited without a plugin release); otherwise fall back to whatever the author's own
/// `manifest.json` reports (sourced from their `plugin.zig.zon`, see `manifest.zig`'s doc
/// comment) — this is what lets an author skip hand-duplicating it into their one registry PR.
/// `author` follows the same precedence, but `publisher` deliberately follows none of it: see
/// `publisherFromUrl`.
///
/// Returns whether the row actually changed. The `WHERE` on the `DO UPDATE` is what makes that
/// answer meaningful *and* keeps `registry.db` byte-stable: SQLite rewrites a row on an
/// unguarded `UPDATE` even when every value is identical, and any dirtied page bumps the file's
/// header change counter — which is enough for `aggregate.yml`'s "commit if changed" check to
/// fire on a run that learned nothing. `last_ok_at` is deliberately *not* set here; see
/// `touchLastOk`.
fn upsertPlugin(
    database: *db_mod.Db,
    entry: registry_entry.RegistryEntry,
    manifest: manifest_mod.Manifest,
    today: []const u8,
) !bool {
    const description = if (entry.description.len > 0) entry.description else manifest.description;
    const author = if (entry.author.len > 0) entry.author else manifest.author;
    const publisher = publisherFromUrl(entry.manifest_url) orelse "";
    try database.exec(
        \\INSERT INTO plugins (id, name, description, author, author_url, publisher, homepage, manifest_url, date_added, last_ok_at, last_error)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        \\ON CONFLICT(id) DO UPDATE SET
        \\  name = excluded.name,
        \\  description = excluded.description,
        \\  author = excluded.author,
        \\  author_url = excluded.author_url,
        \\  publisher = excluded.publisher,
        \\  homepage = excluded.homepage,
        \\  manifest_url = excluded.manifest_url,
        \\  last_error = NULL
        \\WHERE name IS NOT excluded.name
        \\   OR description IS NOT excluded.description
        \\   OR author IS NOT excluded.author
        \\   OR author_url IS NOT excluded.author_url
        \\   OR publisher IS NOT excluded.publisher
        \\   OR homepage IS NOT excluded.homepage
        \\   OR manifest_url IS NOT excluded.manifest_url
        \\   OR last_error IS NOT NULL
    ,
        .{},
        .{
            entry.id,           entry.name, description, author, manifest.author_url,
            publisher,          entry.homepage,          entry.manifest_url,
            today,              today,
        },
    );
    return database.rowsAffected() > 0;
}

/// Advance `last_ok_at` — the date of the last ingest that actually *changed* this plugin's
/// data, not the last one that merely re-fetched an unchanged manifest. Called only when some
/// upsert reported a change, which is what keeps a quiet scheduled run from writing to the
/// database at all (and so from producing a commit); `export`'s `summary.json` `generated` field
/// reads the same column, so it now means "the catalog last changed on", which is the more
/// useful claim to publish anyway.
fn touchLastOk(database: *db_mod.Db, plugin_id: []const u8, today: []const u8) !void {
    try database.exec(
        "UPDATE plugins SET last_ok_at = ? WHERE id = ? AND last_ok_at IS NOT ?",
        .{},
        .{ today, plugin_id, today },
    );
}

/// The account a plugin's binaries are actually published from, parsed out of its
/// `manifest_url` — e.g. `https://github.com/fizzyedit/pixi/releases/latest/download/manifest.json`
/// → `fizzyedit`.
///
/// This is the *attestable* half of the store's attribution, and the reason it is derived here
/// rather than read from a field: `manifest_url` is where the downloaded binary actually comes
/// from, and it's fixed in a PR-reviewed `registry/<id>.json`, so it can't be restated by a
/// plugin describing itself. A self-asserted `author` string sits beside it in the UI, clearly
/// as the softer claim.
///
/// Null for any host we can't attribute this way (a self-hosted manifest on an arbitrary
/// domain) — the store then shows the author credit alone rather than inventing a publisher.
fn publisherFromUrl(manifest_url: []const u8) ?[]const u8 {
    const schemes = [_][]const u8{ "https://", "http://" };
    var rest: []const u8 = manifest_url;
    for (schemes) |s| {
        if (std.ascii.startsWithIgnoreCase(manifest_url, s)) {
            rest = manifest_url[s.len..];
            break;
        }
    } else return null;

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..slash];
    if (!std.ascii.eqlIgnoreCase(host, "github.com")) return null;

    const path = rest[slash + 1 ..];
    const owner_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    const owner = path[0..owner_end];
    return if (owner.len > 0) owner else null;
}

test "publisherFromUrl extracts the GitHub owner" {
    try std.testing.expectEqualStrings("fizzyedit", publisherFromUrl(
        "https://github.com/fizzyedit/pixi/releases/latest/download/manifest.json",
    ).?);
    try std.testing.expectEqualStrings("foxnne", publisherFromUrl("http://github.com/foxnne/x").?);
}

test "publisherFromUrl declines what it cannot attribute" {
    // Self-hosted manifest: a real publisher, but not one this heuristic can name.
    try std.testing.expectEqual(@as(?[]const u8, null), publisherFromUrl("https://plugins.example.test/m.json"));
    // Not a URL at all, and a scheme we never open.
    try std.testing.expectEqual(@as(?[]const u8, null), publisherFromUrl("github.com/foxnne/x"));
    try std.testing.expectEqual(@as(?[]const u8, null), publisherFromUrl("file:///etc/passwd"));
    // Host present but no owner segment.
    try std.testing.expectEqual(@as(?[]const u8, null), publisherFromUrl("https://github.com/"));
}

/// Same registry-wins/manifest-falls-back relationship as `upsertPlugin`'s `description` — see
/// its doc comment. Returns whether the stored tag set changed.
///
/// The delete-then-reinsert is unavoidable (a tag can disappear from a manifest, and there is no
/// "replace this set" statement), but it must not run when the set is unchanged: `plugin_tags` is
/// a rowid table, so reinserting the same tags hands them *new, higher rowids* every time —
/// identical data at different bytes, which is what made every scheduled run commit a fresh
/// `registry.db`. So compare first, and only rewrite on a real difference.
fn upsertTags(
    allocator: std.mem.Allocator,
    database: *db_mod.Db,
    entry: registry_entry.RegistryEntry,
    manifest: manifest_mod.Manifest,
) !bool {
    const tags = if (entry.tags.len > 0) entry.tags else manifest.tags;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both sides normalized the same way (sorted + deduped) so the comparison sees the set the
    // table would actually hold, not the manifest's incidental order.
    const wanted = try arena.dupe([]const u8, tags);
    std.mem.sort([]const u8, wanted, {}, lessThanStr);
    const deduped = dedupeSorted(wanted);

    var stmt = try database.prepare("SELECT tag FROM plugin_tags WHERE plugin_id = ? ORDER BY tag");
    defer stmt.deinit();
    const existing = try stmt.all([]const u8, arena, .{}, .{entry.id});

    if (existing.len == deduped.len) {
        var same = true;
        for (existing, deduped) |a, b| {
            if (!std.mem.eql(u8, a, b)) {
                same = false;
                break;
            }
        }
        if (same) return false;
    }

    try database.exec("DELETE FROM plugin_tags WHERE plugin_id = ?", .{}, .{entry.id});
    for (deduped) |tag| {
        try database.exec(
            "INSERT OR IGNORE INTO plugin_tags (plugin_id, tag) VALUES (?, ?)",
            .{},
            .{ entry.id, tag },
        );
    }
    return true;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// In-place dedupe of an already-sorted slice, returning the unique prefix.
fn dedupeSorted(sorted: [][]const u8) [][]const u8 {
    var n: usize = 0;
    for (sorted) |s| {
        if (n > 0 and std.mem.eql(u8, sorted[n - 1], s)) continue;
        sorted[n] = s;
        n += 1;
    }
    return sorted[0..n];
}

/// Upsert every release + its downloads. Never deletes an existing release/download row that the
/// current manifest happens to omit — the database is the durable history an author's own
/// manifest isn't required to retain (see module doc and PLAN.md). Returns whether any release or
/// download row was inserted or actually modified; the `WHERE` guards exist for the same reason
/// as `upsertPlugin`'s.
fn upsertReleases(database: *db_mod.Db, plugin_id: []const u8, releases: []const manifest_mod.Release) !bool {
    var changed = false;
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
            \\WHERE min_sdk_version IS NOT excluded.min_sdk_version
            \\   OR fizzy_sdk_version IS NOT excluded.fizzy_sdk_version
            \\   OR published IS NOT excluded.published
        ,
            .{},
            .{ plugin_id, release.version, fingerprint, release.min_sdk_version, release.fizzy_sdk_version, release.published },
        );
        if (database.rowsAffected() > 0) changed = true;

        var it = release.downloads.map.iterator();
        while (it.next()) |kv| {
            try database.exec(
                \\INSERT INTO downloads (plugin_id, version, abi_fingerprint, os_arch, url, sha256)
                \\VALUES (?, ?, ?, ?, ?, ?)
                \\ON CONFLICT(plugin_id, version, abi_fingerprint, os_arch) DO UPDATE SET
                \\  url = excluded.url,
                \\  sha256 = excluded.sha256
                \\WHERE url IS NOT excluded.url
                \\   OR sha256 IS NOT excluded.sha256
            ,
                .{},
                .{ plugin_id, release.version, fingerprint, kv.key_ptr.*, kv.value_ptr.url, kv.value_ptr.sha256 },
            );
            if (database.rowsAffected() > 0) changed = true;
        }
    }
    return changed;
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
///
/// Existence is asked separately rather than read off `rowsAffected`, because the UPDATE is
/// guarded: an outage that repeats the same message every 6 hours must not rewrite the row (and
/// so commit) each time, which would have made "nothing changed" impossible precisely when
/// nothing is changing.
fn markLastError(database: *db_mod.Db, plugin_id: []const u8, message: []const u8) !bool {
    const exists = (try database.one(usize, "SELECT COUNT(*) FROM plugins WHERE id = ?", .{}, .{plugin_id})) orelse 0;
    if (exists == 0) return false;
    try database.exec(
        "UPDATE plugins SET last_error = ? WHERE id = ? AND last_error IS NOT ?",
        .{},
        .{ message, plugin_id, message },
    );
    return true;
}

const test_manifest_json =
    \\{
    \\  "id": "pixi",
    \\  "name": "Pixi",
    \\  "description": "Pixel-art editor",
    \\  "author": "foxnne",
    \\  "author_url": "https://github.com/foxnne",
    \\  "tags": ["pixel-art", "editor"],
    \\  "releases": [{
    \\    "version": "0.1.5",
    \\    "abi_fingerprint": "0x98fcfe4f79edb50d",
    \\    "min_sdk_version": "0.9.0",
    \\    "fizzy_sdk_version": "0.9.0",
    \\    "published": "2026-07-01",
    \\    "downloads": {
    \\      "macos-aarch64": { "url": "https://example.test/pixi.dylib", "sha256": "abc123" }
    \\    }
    \\  }]
    \\}
;

const test_entry: registry_entry.RegistryEntry = .{
    .id = "pixi",
    .name = "Pixi",
    .homepage = "https://github.com/fizzyedit/pixi",
    .manifest_url = "https://github.com/fizzyedit/pixi/releases/latest/download/manifest.json",
};

/// One plugin's worth of ingest, exactly as `run` sequences it.
fn ingestOne(
    allocator: std.mem.Allocator,
    database: *db_mod.Db,
    entry: registry_entry.RegistryEntry,
    manifest: manifest_mod.Manifest,
    today: []const u8,
) !bool {
    var changed = try upsertPlugin(database, entry, manifest, today);
    changed = try upsertTags(allocator, database, entry, manifest) or changed;
    changed = try upsertReleases(database, entry.id, manifest.releases) or changed;
    if (changed) try touchLastOk(database, entry.id, today);
    return changed;
}

test "re-ingesting identical data reports no change" {
    const allocator = std.testing.allocator;
    var parsed = try manifest_mod.parseAndValidate(allocator, test_manifest_json, "pixi");
    defer parsed.deinit();

    var database = try db_mod.openMemory();
    defer database.deinit();

    try std.testing.expect(try ingestOne(allocator, &database, test_entry, parsed.value, "2026-07-30"));
    // Same manifest, a later day: nothing about the plugin changed, so nothing — `last_ok_at`
    // included — may be written.
    try std.testing.expect(!try ingestOne(allocator, &database, test_entry, parsed.value, "2026-07-31"));

    const last_ok = try database.oneAlloc([]const u8, allocator, "SELECT last_ok_at FROM plugins WHERE id = ?", .{}, .{"pixi"});
    defer if (last_ok) |v| allocator.free(v);
    try std.testing.expectEqualStrings("2026-07-30", last_ok orelse return error.MissingRow);

    // Tags survive intact rather than being wiped by a skipped rewrite.
    const tag_count = try database.one(usize, "SELECT COUNT(*) FROM plugin_tags WHERE plugin_id = ?", .{}, .{"pixi"});
    try std.testing.expectEqual(@as(?usize, 2), tag_count);
}

test "a real manifest change is still ingested and moves last_ok_at" {
    const allocator = std.testing.allocator;
    var parsed = try manifest_mod.parseAndValidate(allocator, test_manifest_json, "pixi");
    defer parsed.deinit();

    var database = try db_mod.openMemory();
    defer database.deinit();
    _ = try ingestOne(allocator, &database, test_entry, parsed.value, "2026-07-30");

    var updated = parsed.value;
    updated.description = "Pixel-art editor, now with atlases";
    updated.tags = &.{ "pixel-art", "editor", "sprites" };
    try std.testing.expect(try ingestOne(allocator, &database, test_entry, updated, "2026-07-31"));

    const last_ok = try database.oneAlloc([]const u8, allocator, "SELECT last_ok_at FROM plugins WHERE id = ?", .{}, .{"pixi"});
    defer if (last_ok) |v| allocator.free(v);
    try std.testing.expectEqualStrings("2026-07-31", last_ok orelse return error.MissingRow);

    const tag_count = try database.one(usize, "SELECT COUNT(*) FROM plugin_tags WHERE plugin_id = ?", .{}, .{"pixi"});
    try std.testing.expectEqual(@as(?usize, 3), tag_count);
}

test "re-ingesting identical data leaves registry.db byte-identical" {
    // The property `aggregate.yml` actually depends on, and the one an in-memory database cannot
    // observe: SQLite bumps the file's header change counter on *any* dirtied page, and
    // `plugin_tags` hands out fresh rowids on every delete-then-reinsert. Both used to make a
    // quiet scheduled run produce a "chore: refresh registry.db" commit that carried no news.
    const allocator = std.testing.allocator;
    var parsed = try manifest_mod.parseAndValidate(allocator, test_manifest_json, "pixi");
    defer parsed.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/registry.db", .{tmp.sub_path}, 0);
    defer allocator.free(dir_path);

    {
        var database = try db_mod.open(dir_path);
        defer database.deinit();
        _ = try ingestOne(allocator, &database, test_entry, parsed.value, "2026-07-30");
    }
    const first = try tmp.dir.readFileAlloc(std.testing.io, "registry.db", allocator, .limited(4 << 20));
    defer allocator.free(first);

    {
        var database = try db_mod.open(dir_path);
        defer database.deinit();
        _ = try ingestOne(allocator, &database, test_entry, parsed.value, "2026-07-31");
    }
    const second = try tmp.dir.readFileAlloc(std.testing.io, "registry.db", allocator, .limited(4 << 20));
    defer allocator.free(second);

    try std.testing.expectEqualSlices(u8, first, second);
}
