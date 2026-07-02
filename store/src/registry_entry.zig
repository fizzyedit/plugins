//! `registry/<id>.json`: the small, author-submitted pointer file this repo's PR flow reviews.
//! Structural rules mirror `scripts/aggregate.py`'s `load_registry_entries` exactly — a malformed
//! file here is a hard error, since these land via reviewed PRs and must be fixed, not silently
//! skipped (contrast with a bad *manifest*, fetched over the network, which is skipped — see
//! `manifest.zig`).
const std = @import("std");

pub const RegistryEntry = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    description: []const u8 = "",
    author: []const u8 = "",
    homepage: []const u8 = "",
    tags: []const []const u8 = &.{},
    manifest_url: []const u8 = "",
};

pub const RegistryError = error{
    NotAnObject,
    MissingId,
    MissingName,
    MissingManifestUrl,
    IdFilenameMismatch,
};

/// Parse and structurally validate a single `registry/<id>.json` document. `filename_stem` is
/// the file's basename without extension (e.g. `"pixi"` for `registry/pixi.json`) — the id must
/// equal it, which is what actually prevents two different files from ever claiming the same
/// plugin id (the database's `plugins.id` PRIMARY KEY is the second, DB-level guarantee).
pub fn parseAndValidate(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    filename_stem: []const u8,
) (std.json.ParseError(std.json.Scanner) || RegistryError)!std.json.Parsed(RegistryEntry) {
    var parsed = try std.json.parseFromSlice(RegistryEntry, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    const entry = parsed.value;
    if (entry.id.len == 0) return RegistryError.MissingId;
    if (entry.name.len == 0) return RegistryError.MissingName;
    if (entry.manifest_url.len == 0) return RegistryError.MissingManifestUrl;
    if (!std.mem.eql(u8, entry.id, filename_stem)) return RegistryError.IdFilenameMismatch;

    return parsed;
}

/// One successfully loaded `registry/<id>.json`, owning its own arena.
pub const LoadedEntry = struct {
    parsed: std.json.Parsed(RegistryEntry),

    pub fn value(self: LoadedEntry) RegistryEntry {
        return self.parsed.value;
    }

    pub fn deinit(self: *LoadedEntry) void {
        self.parsed.deinit();
    }
};

/// Load every `registry/*.json` file under `registry_dir_path`. Any malformed entry is a hard
/// error (see module doc) — the caller (a PR check or `ingest`) should surface it and stop.
pub fn loadAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    registry_dir_path: []const u8,
) ![]LoadedEntry {
    var dir = try std.Io.Dir.cwd().openDir(io, registry_dir_path, .{ .iterate = true });
    defer dir.close(io);

    var entries: std.ArrayListUnmanaged(LoadedEntry) = .empty;
    errdefer {
        for (entries.items) |*e| e.deinit();
        entries.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |dirent| {
        if (dirent.kind != .file) continue;
        if (!std.mem.endsWith(u8, dirent.name, ".json")) continue;
        const stem = dirent.name[0 .. dirent.name.len - ".json".len];

        const bytes = try dir.readFileAlloc(io, dirent.name, allocator, .unlimited);
        defer allocator.free(bytes);

        const loaded = parseAndValidate(allocator, bytes, stem) catch |err| {
            std.log.err("registry/{s}: {s}", .{ dirent.name, @errorName(err) });
            return err;
        };
        try entries.append(allocator, .{ .parsed = loaded });
    }

    // Deterministic order (directory iteration order is unspecified) so a re-run without any
    // registry change produces byte-identical `ingest` behavior/logging.
    std.sort.pdq(LoadedEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: LoadedEntry, b: LoadedEntry) bool {
            return std.mem.lessThan(u8, a.value().id, b.value().id);
        }
    }.lessThan);

    return entries.toOwnedSlice(allocator);
}

test "parseAndValidate accepts a well-formed entry" {
    const json =
        \\{"id":"pixi","name":"Pixi","manifest_url":"https://example.test/manifest.json"}
    ;
    var parsed = try parseAndValidate(std.testing.allocator, json, "pixi");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Pixi", parsed.value.name);
}

test "parseAndValidate rejects id/filename mismatch" {
    const json =
        \\{"id":"pixi","name":"Pixi","manifest_url":"https://example.test/manifest.json"}
    ;
    try std.testing.expectError(
        RegistryError.IdFilenameMismatch,
        parseAndValidate(std.testing.allocator, json, "not-pixi"),
    );
}

test "parseAndValidate rejects missing manifest_url" {
    const json =
        \\{"id":"pixi","name":"Pixi"}
    ;
    try std.testing.expectError(
        RegistryError.MissingManifestUrl,
        parseAndValidate(std.testing.allocator, json, "pixi"),
    );
}
