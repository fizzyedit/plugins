//! `store export`: dump `registry.db` into the static files the Fizzy client fetches —
//! `catalog/summary.json` (every plugin, no releases) and one `catalog/<abi_fingerprint>/releases.json`
//! per fingerprint the store has ever built a release for (each plugin contributes at most one
//! release: the newest matching that exact fingerprint). See `catalog.zig` for the JSON shapes
//! and PLAN.md Phase 3 for why this replaces a single flat `index.json`.
//!
//! "Newest" is picked by parsing `version` as semver (`std.SemanticVersion`), matching how the
//! client's own `compat.selectRelease` already resolves ties — not by SQL `ORDER BY version`,
//! which would sort "0.10.0" before "0.9.0" lexicographically.
const std = @import("std");

const db_mod = @import("db.zig");
const catalog = @import("catalog.zig");
const time_fmt = @import("time_fmt.zig");

const Options = struct {
    db_path: []const u8 = "registry.db",
    /// Relative to `store/`'s own directory — the plugins repo's Pages root is `plugins/`
    /// (confusingly, a subdirectory named the same as the repo), matching `aggregate.yml`'s
    /// `Upload Pages artifact` step.
    out_dir: []const u8 = "../plugins/catalog",
};

fn parseArgs(args: []const []const u8) Options {
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--db") and i + 1 < args.len) {
            i += 1;
            opts.db_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            opts.out_dir = args[i];
        }
    }
    return opts;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    const opts = parseArgs(args);

    const db_path_z = try allocator.dupeZ(u8, opts.db_path);
    defer allocator.free(db_path_z);
    var database = try db_mod.open(db_path_z);
    defer database.deinit();

    const generated = try time_fmt.nowIso8601(allocator, io);
    defer allocator.free(generated);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summary = try buildSummary(arena, &database, generated);
    try writeJson(allocator, io, opts.out_dir, "summary.json", summary);

    const fingerprints = try listFingerprints(arena, &database);
    for (fingerprints) |fp| {
        const shard = try buildShard(arena, &database, fp, generated);
        const rel_path = try std.fmt.allocPrint(arena, "{s}/releases.json", .{fp});
        try writeJson(allocator, io, opts.out_dir, rel_path, shard);
    }

    std.debug.print(
        "export done: summary.json ({d} plugin(s)) + {d} fingerprint shard(s) written to {s}\n",
        .{ summary.plugins.len, fingerprints.len, opts.out_dir },
    );
}

/// Every fingerprint the store has ever built a release for, oldest-looking-string-first (order
/// doesn't matter functionally — each becomes an independent file).
pub fn listFingerprints(arena: std.mem.Allocator, database: *db_mod.Db) ![]const []const u8 {
    var stmt = try database.prepare("SELECT DISTINCT abi_fingerprint FROM releases ORDER BY abi_fingerprint");
    defer stmt.deinit();
    return stmt.all([]const u8, arena, .{}, .{});
}

const PluginRow = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    author: []const u8,
    homepage: []const u8,
    date_added: []const u8,
};

pub fn buildSummary(arena: std.mem.Allocator, database: *db_mod.Db, generated: []const u8) !catalog.Summary {
    var stmt = try database.prepare(
        "SELECT id, name, description, author, homepage, date_added FROM plugins ORDER BY id",
    );
    defer stmt.deinit();

    var entries: std.ArrayListUnmanaged(catalog.SummaryEntry) = .empty;
    var iter = try stmt.iterator(PluginRow, .{});
    while (try iter.nextAlloc(arena, .{})) |row| {
        try entries.append(arena, .{
            .id = row.id,
            .name = row.name,
            .description = row.description,
            .author = row.author,
            .homepage = row.homepage,
            .tags = try loadTags(arena, database, row.id),
            .date_added = row.date_added,
            .latest_version = try latestVersion(arena, database, row.id) orelse "",
        });
    }

    return .{ .generated = generated, .plugins = entries.items };
}

fn loadTags(arena: std.mem.Allocator, database: *db_mod.Db, plugin_id: []const u8) ![]const []const u8 {
    var stmt = try database.prepare("SELECT tag FROM plugin_tags WHERE plugin_id = ? ORDER BY tag");
    defer stmt.deinit();
    return stmt.all([]const u8, arena, .{}, .{plugin_id});
}

/// Highest semver `plugin_id` has ever published, across every fingerprint (see
/// `catalog.SummaryEntry.latest_version`). Semver-compared in Zig, not `ORDER BY version`
/// (which would sort "0.10.0" before "0.9.0"); non-semver versions are skipped.
fn latestVersion(arena: std.mem.Allocator, database: *db_mod.Db, plugin_id: []const u8) !?[]const u8 {
    var stmt = try database.prepare("SELECT DISTINCT version FROM releases WHERE plugin_id = ?");
    defer stmt.deinit();
    const versions = try stmt.all([]const u8, arena, .{}, .{plugin_id});

    var best: ?[]const u8 = null;
    var best_ver: std.SemanticVersion = undefined;
    for (versions) |version| {
        const ver = std.SemanticVersion.parse(version) catch continue;
        if (best == null or ver.order(best_ver) == .gt) {
            best = version;
            best_ver = ver;
        }
    }
    return best;
}

const ReleaseRow = struct {
    version: []const u8,
    min_sdk_version: []const u8,
    fizzy_sdk_version: []const u8,
    published: []const u8,
};

const DownloadRow = struct {
    os_arch: []const u8,
    url: []const u8,
    sha256: []const u8,
};

pub fn buildShard(
    arena: std.mem.Allocator,
    database: *db_mod.Db,
    abi_fingerprint: []const u8,
    generated: []const u8,
) !catalog.ReleaseShard {
    var plugin_ids_stmt = try database.prepare("SELECT id FROM plugins ORDER BY id");
    defer plugin_ids_stmt.deinit();
    const plugin_ids = try plugin_ids_stmt.all([]const u8, arena, .{}, .{});

    var releases: std.StringArrayHashMapUnmanaged(catalog.ShardRelease) = .empty;
    for (plugin_ids) |plugin_id| {
        if (try bestRelease(arena, database, plugin_id, abi_fingerprint)) |release| {
            try releases.put(arena, plugin_id, release);
        }
    }

    return .{ .generated = generated, .abi_fingerprint = abi_fingerprint, .releases = .{ .map = releases } };
}

/// The newest (semver) release `plugin_id` has published for `abi_fingerprint`, with its
/// downloads attached, or `null` if it has never shipped a build for this fingerprint. A release
/// whose `version` doesn't parse as semver is skipped rather than crashing the export — mirrors
/// `compat.selectRelease`'s `catch continue`.
fn bestRelease(
    arena: std.mem.Allocator,
    database: *db_mod.Db,
    plugin_id: []const u8,
    abi_fingerprint: []const u8,
) !?catalog.ShardRelease {
    var stmt = try database.prepare(
        "SELECT version, min_sdk_version, fizzy_sdk_version, published FROM releases WHERE plugin_id = ? AND abi_fingerprint = ?",
    );
    defer stmt.deinit();
    const rows = try stmt.all(ReleaseRow, arena, .{}, .{ plugin_id, abi_fingerprint });

    var best: ?ReleaseRow = null;
    var best_ver: std.SemanticVersion = undefined;
    for (rows) |row| {
        const ver = std.SemanticVersion.parse(row.version) catch continue;
        if (best == null or ver.order(best_ver) == .gt) {
            best = row;
            best_ver = ver;
        }
    }
    const winner = best orelse return null;

    const downloads = try loadDownloads(arena, database, plugin_id, winner.version, abi_fingerprint);
    return .{
        .version = winner.version,
        .min_sdk_version = winner.min_sdk_version,
        .fizzy_sdk_version = winner.fizzy_sdk_version,
        .published = winner.published,
        .downloads = .{ .map = downloads },
    };
}

fn loadDownloads(
    arena: std.mem.Allocator,
    database: *db_mod.Db,
    plugin_id: []const u8,
    version: []const u8,
    abi_fingerprint: []const u8,
) !std.StringArrayHashMapUnmanaged(catalog.Download) {
    var stmt = try database.prepare(
        "SELECT os_arch, url, sha256 FROM downloads WHERE plugin_id = ? AND version = ? AND abi_fingerprint = ?",
    );
    defer stmt.deinit();
    const rows = try stmt.all(DownloadRow, arena, .{}, .{ plugin_id, version, abi_fingerprint });

    var map: std.StringArrayHashMapUnmanaged(catalog.Download) = .empty;
    for (rows) |row| {
        try map.put(arena, row.os_arch, .{ .url = row.url, .sha256 = row.sha256 });
    }
    return map;
}

fn writeJson(allocator: std.mem.Allocator, io: std.Io, out_dir: []const u8, rel_path: []const u8, value: anytype) !void {
    const full_path = try std.fs.path.join(allocator, &.{ out_dir, rel_path });
    defer allocator.free(full_path);

    if (std.fs.path.dirname(full_path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    const json_bytes = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(json_bytes);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full_path, .data = json_bytes });
}

test "buildSummary lists plugins with tags and cross-fingerprint latest_version" {
    var database = try db_mod.openMemory();
    defer database.deinit();

    try database.exec(
        "INSERT INTO plugins (id, name, description, author, homepage, manifest_url, date_added) VALUES (?, ?, ?, ?, ?, ?, ?)",
        .{},
        .{ "pixi", "Pixi", "Pixel art editor", "foxnne", "https://github.com/fizzyedit/pixi", "https://x/manifest.json", "2026-07-01" },
    );
    try database.exec("INSERT INTO plugin_tags (plugin_id, tag) VALUES (?, ?)", .{}, .{ "pixi", "editor" });
    try database.exec("INSERT INTO plugin_tags (plugin_id, tag) VALUES (?, ?)", .{}, .{ "pixi", "pixel-art" });
    // latest_version must span fingerprints ("0.10.0" on a newer SDK vs "0.9.0" on an older one)
    // and compare as semver, not lexicographically.
    inline for (.{ .{ "0.9.0", "0xold" }, .{ "0.10.0", "0xnew" } }) |rel| {
        try database.exec(
            "INSERT INTO releases (plugin_id, version, abi_fingerprint, min_sdk_version, fizzy_sdk_version, published) VALUES (?, ?, ?, ?, ?, ?)",
            .{},
            .{ "pixi", rel[0], rel[1], "0.9.0", "0.9.0", "2026-07-01" },
        );
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const summary = try buildSummary(arena_state.allocator(), &database, "2026-07-02T00:00:00Z");
    try std.testing.expectEqual(@as(usize, 1), summary.plugins.len);
    try std.testing.expectEqualStrings("Pixi", summary.plugins[0].name);
    try std.testing.expectEqual(@as(usize, 2), summary.plugins[0].tags.len);
    try std.testing.expectEqualStrings("editor", summary.plugins[0].tags[0]);
    try std.testing.expectEqualStrings("0.10.0", summary.plugins[0].latest_version);
}

test "buildSummary leaves latest_version empty for a plugin with no releases" {
    var database = try db_mod.openMemory();
    defer database.deinit();

    try database.exec(
        "INSERT INTO plugins (id, name, manifest_url, date_added) VALUES (?, ?, ?, ?)",
        .{},
        .{ "bare", "Bare", "https://x/manifest.json", "2026-07-01" },
    );

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const summary = try buildSummary(arena_state.allocator(), &database, "2026-07-02T00:00:00Z");
    try std.testing.expectEqualStrings("", summary.plugins[0].latest_version);
}

test "buildShard picks the semver-newest release per plugin, not lexicographic" {
    var database = try db_mod.openMemory();
    defer database.deinit();

    try database.exec(
        "INSERT INTO plugins (id, name, manifest_url, date_added) VALUES (?, ?, ?, ?)",
        .{},
        .{ "pixi", "Pixi", "https://x/manifest.json", "2026-07-01" },
    );
    // Lexicographically "0.9.0" > "0.10.0", but semver says the opposite.
    inline for (.{ "0.9.0", "0.10.0" }) |version| {
        try database.exec(
            "INSERT INTO releases (plugin_id, version, abi_fingerprint, min_sdk_version, fizzy_sdk_version, published) VALUES (?, ?, ?, ?, ?, ?)",
            .{},
            .{ "pixi", version, "0xabc", "0.9.0", "0.9.0", "2026-07-01" },
        );
        try database.exec(
            "INSERT INTO downloads (plugin_id, version, abi_fingerprint, os_arch, url, sha256) VALUES (?, ?, ?, ?, ?, ?)",
            .{},
            .{ "pixi", version, "0xabc", "macos-aarch64", "https://x/pixi.dylib", "sha" },
        );
    }
    // A different fingerprint must land in a different shard entirely.
    try database.exec(
        "INSERT INTO releases (plugin_id, version, abi_fingerprint, min_sdk_version, fizzy_sdk_version, published) VALUES (?, ?, ?, ?, ?, ?)",
        .{},
        .{ "pixi", "0.1.0", "0xold", "0.8.0", "0.8.0", "2026-06-01" },
    );

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fingerprints = try listFingerprints(arena, &database);
    try std.testing.expectEqual(@as(usize, 2), fingerprints.len);

    const shard = try buildShard(arena, &database, "0xabc", "2026-07-02T00:00:00Z");
    try std.testing.expectEqual(@as(usize, 1), shard.releases.map.count());
    const release = shard.releases.map.get("pixi") orelse return error.MissingRelease;
    try std.testing.expectEqualStrings("0.10.0", release.version);
    try std.testing.expectEqual(@as(usize, 1), release.downloads.map.count());

    const old_shard = try buildShard(arena, &database, "0xold", "2026-07-02T00:00:00Z");
    const old_release = old_shard.releases.map.get("pixi") orelse return error.MissingRelease;
    try std.testing.expectEqualStrings("0.1.0", old_release.version);
}

test "buildShard omits a plugin with no release for that fingerprint" {
    var database = try db_mod.openMemory();
    defer database.deinit();

    try database.exec(
        "INSERT INTO plugins (id, name, manifest_url, date_added) VALUES (?, ?, ?, ?)",
        .{},
        .{ "pixi", "Pixi", "https://x/manifest.json", "2026-07-01" },
    );
    // No releases inserted at all for "pixi".

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const shard = try buildShard(arena_state.allocator(), &database, "0xabc", "2026-07-02T00:00:00Z");
    try std.testing.expectEqual(@as(usize, 0), shard.releases.map.count());
}
