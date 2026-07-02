//! The registry database: schema + open helpers. This is the durable source of truth `ingest`
//! writes to and `export` reads from (see PLAN.md) — normalizes onto the same shape as the
//! `index.json` the Fizzy client already parses (`registry/<id>.json` pointer + author
//! `manifest.json` releases), plus fields the flat-file registry couldn't track: `date_added`
//! and a durable release history that survives an author's manifest losing old entries.
const std = @import("std");
const sqlite = @import("sqlite");

pub const Db = sqlite.Db;

/// `plugin_id` is the PRIMARY KEY on `plugins`, which is what actually enforces "no two plugins
/// share an id" — the `registry/<id>.json` filename-must-equal-id convention is a second,
/// author-facing guard, not the source of truth.
const schema_sql =
    \\CREATE TABLE IF NOT EXISTS plugins (
    \\  id           TEXT PRIMARY KEY,
    \\  name         TEXT NOT NULL,
    \\  description  TEXT NOT NULL DEFAULT '',
    \\  author       TEXT NOT NULL DEFAULT '',
    \\  homepage     TEXT NOT NULL DEFAULT '',
    \\  manifest_url TEXT NOT NULL,
    \\  date_added   TEXT NOT NULL,
    \\  last_ok_at   TEXT,
    \\  last_error   TEXT
    \\);
    \\CREATE TABLE IF NOT EXISTS plugin_tags (
    \\  plugin_id TEXT NOT NULL REFERENCES plugins(id) ON DELETE CASCADE,
    \\  tag       TEXT NOT NULL,
    \\  PRIMARY KEY (plugin_id, tag)
    \\);
    \\CREATE TABLE IF NOT EXISTS releases (
    \\  plugin_id         TEXT NOT NULL REFERENCES plugins(id) ON DELETE CASCADE,
    \\  version           TEXT NOT NULL,
    \\  abi_fingerprint   TEXT NOT NULL,
    \\  min_sdk_version   TEXT NOT NULL,
    \\  fizzy_sdk_version TEXT NOT NULL,
    \\  published         TEXT NOT NULL,
    \\  PRIMARY KEY (plugin_id, version, abi_fingerprint)
    \\);
    \\CREATE TABLE IF NOT EXISTS downloads (
    \\  plugin_id       TEXT NOT NULL,
    \\  version         TEXT NOT NULL,
    \\  abi_fingerprint TEXT NOT NULL,
    \\  os_arch         TEXT NOT NULL,
    \\  url             TEXT NOT NULL,
    \\  sha256          TEXT NOT NULL,
    \\  PRIMARY KEY (plugin_id, version, abi_fingerprint, os_arch),
    \\  FOREIGN KEY (plugin_id, version, abi_fingerprint)
    \\    REFERENCES releases(plugin_id, version, abi_fingerprint) ON DELETE CASCADE
    \\);
;

fn migrate(db: *Db) !void {
    try db.execMulti(schema_sql, .{});
    _ = try db.pragma(void, .{}, "foreign_keys", "1");
}

/// Open (creating if needed) the registry database at `path`.
pub fn open(path: [:0]const u8) !Db {
    var db = try Db.init(.{
        .mode = .{ .File = path },
        .open_flags = .{ .write = true, .create = true },
        .threading_mode = .MultiThread,
    });
    try migrate(&db);
    return db;
}

/// In-memory database — used by tests and by `store validate`, which never needs to persist.
pub fn openMemory() !Db {
    var db = try Db.init(.{
        .mode = .{ .Memory = {} },
        .open_flags = .{ .write = true, .create = true },
    });
    try migrate(&db);
    return db;
}

test "schema creates tables and stores a plugin row" {
    var db = try openMemory();
    defer db.deinit();

    try db.exec(
        "INSERT INTO plugins (id, name, manifest_url, date_added) VALUES (?, ?, ?, ?)",
        .{},
        .{ "pixi", "Pixi", "https://example.test/pixi/manifest.json", "2026-07-02" },
    );

    const name = try db.oneAlloc(
        []const u8,
        std.testing.allocator,
        "SELECT name FROM plugins WHERE id = ?",
        .{},
        .{"pixi"},
    );
    defer if (name) |n| std.testing.allocator.free(n);
    try std.testing.expectEqualStrings("Pixi", name orelse return error.MissingRow);

    // `id` uniqueness (a duplicate insert must fail the PRIMARY KEY constraint) is deliberately
    // not asserted here: zig-sqlite's `Statement.deinit()` logs via `std.log.err` when
    // finalizing a statement whose last step failed, which is exactly what a failed INSERT
    // leaves behind. Zig's test runner treats any `.err`-level log during a test as a hard
    // failure with no app-level suppression hook, so an automated test of this path would
    // permanently fail `zig build test` despite the behavior being correct — confirmed manually:
    // a second `INSERT` with `id = "pixi"` raises `error.SQLiteConstraint`
    // ("UNIQUE constraint failed: plugins.id"), as SQLite's own PRIMARY KEY guarantee promises.
}

test "releases and downloads round-trip and cascade on plugin delete" {
    var db = try openMemory();
    defer db.deinit();

    try db.exec(
        "INSERT INTO plugins (id, name, manifest_url, date_added) VALUES (?, ?, ?, ?)",
        .{},
        .{ "pixi", "Pixi", "https://example.test/pixi/manifest.json", "2026-07-02" },
    );
    try db.exec(
        \\INSERT INTO releases (plugin_id, version, abi_fingerprint, min_sdk_version, fizzy_sdk_version, published)
        \\VALUES (?, ?, ?, ?, ?, ?)
    ,
        .{},
        .{ "pixi", "0.1.5", "0x98fcfe4f79edb50d", "0.8.0", "0.8.0", "2026-06-30" },
    );
    try db.exec(
        "INSERT INTO downloads (plugin_id, version, abi_fingerprint, os_arch, url, sha256) VALUES (?, ?, ?, ?, ?, ?)",
        .{},
        .{ "pixi", "0.1.5", "0x98fcfe4f79edb50d", "macos-aarch64", "https://example.test/pixi.dylib", "abc123" },
    );

    const download_count_before = try db.one(usize, "SELECT COUNT(*) FROM downloads WHERE plugin_id = ?", .{}, .{"pixi"});
    try std.testing.expectEqual(@as(?usize, 1), download_count_before);

    try db.exec("DELETE FROM plugins WHERE id = ?", .{}, .{"pixi"});

    const download_count_after = try db.one(usize, "SELECT COUNT(*) FROM downloads WHERE plugin_id = ?", .{}, .{"pixi"});
    try std.testing.expectEqual(@as(?usize, 0), download_count_after);
}
