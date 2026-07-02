//! An author's self-hosted `manifest.json` (fetched from `registry/<id>.json`'s `manifest_url`).
//! Shape matches what `fizzyedit/plugin-build-action` publishes and what fizzy's own
//! `src/backend/plugin_store/registry.zig` parses client-side. Unlike a `registry/<id>.json`
//! (reviewed via PR, so malformed = hard error), a bad manifest is the *author's* problem: it is
//! fetched over the network on a schedule, so `ingest` skips it and keeps whatever the database
//! already has for that plugin (last-known-good) — see `ingest.zig`.
const std = @import("std");

pub const Download = struct {
    url: []const u8 = "",
    sha256: []const u8 = "",
};

pub const Release = struct {
    version: []const u8 = "",
    min_sdk_version: []const u8 = "",
    abi_fingerprint: []const u8 = "",
    fizzy_sdk_version: []const u8 = "",
    published: []const u8 = "",
    downloads: std.json.ArrayHashMap(Download) = .{},
};

pub const Manifest = struct {
    id: []const u8 = "",
    releases: []const Release = &.{},
};

pub const ManifestError = error{
    IdMismatch,
    ReleaseMissingVersion,
    ReleaseMissingAbiFingerprint,
    ReleaseMissingDownloads,
    DownloadMissingUrl,
    DownloadMissingSha256,
};

/// Parse and validate a manifest against the `expected_id` from its `registry/<id>.json` entry.
/// Mirrors `aggregate.py`'s `validate_manifest`: every release needs `version` +
/// `abi_fingerprint` + a non-empty `downloads` map, and every download needs `url` + `sha256`.
/// `min_sdk_version`/`fizzy_sdk_version`/`published` are not required — the client (and our own
/// DB schema) treat them as informational, defaulting to `""` when absent.
pub fn parseAndValidate(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected_id: []const u8,
) (std.json.ParseError(std.json.Scanner) || ManifestError)!std.json.Parsed(Manifest) {
    var parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    const manifest = parsed.value;
    if (!std.mem.eql(u8, manifest.id, expected_id)) return ManifestError.IdMismatch;

    for (manifest.releases) |release| {
        if (release.version.len == 0) return ManifestError.ReleaseMissingVersion;
        if (release.abi_fingerprint.len == 0) return ManifestError.ReleaseMissingAbiFingerprint;
        if (release.downloads.map.count() == 0) return ManifestError.ReleaseMissingDownloads;
        var it = release.downloads.map.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.url.len == 0) return ManifestError.DownloadMissingUrl;
            if (kv.value_ptr.sha256.len == 0) return ManifestError.DownloadMissingSha256;
        }
    }

    return parsed;
}

test "parseAndValidate accepts a well-formed manifest" {
    const json =
        \\{"id":"pixi","releases":[{"version":"0.1.5","abi_fingerprint":"0xabc",
        \\"downloads":{"macos-aarch64":{"url":"https://x/pixi.dylib","sha256":"abc123"}}}]}
    ;
    var parsed = try parseAndValidate(std.testing.allocator, json, "pixi");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.releases.len);
}

test "parseAndValidate rejects id mismatch" {
    const json = \\{"id":"other","releases":[]}
    ;
    try std.testing.expectError(ManifestError.IdMismatch, parseAndValidate(std.testing.allocator, json, "pixi"));
}

test "parseAndValidate rejects a release with no downloads" {
    const json =
        \\{"id":"pixi","releases":[{"version":"0.1.5","abi_fingerprint":"0xabc","downloads":{}}]}
    ;
    try std.testing.expectError(
        ManifestError.ReleaseMissingDownloads,
        parseAndValidate(std.testing.allocator, json, "pixi"),
    );
}

test "parseAndValidate rejects a download missing sha256" {
    const json =
        \\{"id":"pixi","releases":[{"version":"0.1.5","abi_fingerprint":"0xabc",
        \\"downloads":{"macos-aarch64":{"url":"https://x/pixi.dylib","sha256":""}}}]}
    ;
    try std.testing.expectError(
        ManifestError.DownloadMissingSha256,
        parseAndValidate(std.testing.allocator, json, "pixi"),
    );
}
