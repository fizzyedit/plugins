//! JSON shapes `store export` writes and (eventually) what the Fizzy client fetches instead of a
//! single flat `index.json`: a small `summary.json` (every plugin, no releases — cheap to fetch
//! and cache on every store-tab open) plus one `<abi_fingerprint>/releases.json` shard per SDK
//! generation the store has ever built for (each plugin contributes at most one release: the
//! newest matching that exact fingerprint). See PLAN.md Phase 3 for why this replaces the
//! monolithic file `fizzy`'s `src/backend/plugin_store/registry.zig` currently fetches.
const std = @import("std");

pub const SummaryEntry = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8 = "",
    author: []const u8 = "",
    homepage: []const u8 = "",
    tags: []const []const u8 = &.{},
    date_added: []const u8,
    /// Highest semver the author has published across *every* fingerprint — precomputed here
    /// because a client only ever fetches its own fingerprint's shard, so it can't see what
    /// other SDK generations have shipped (the store UI shows this as "store v{latest}" even
    /// when the host has no compatible build). Empty when no release parses as semver.
    latest_version: []const u8 = "",
};

pub const Summary = struct {
    schema: u32 = 1,
    generated: []const u8,
    plugins: []const SummaryEntry,
};

pub const Download = struct {
    url: []const u8,
    sha256: []const u8,
};

pub const ShardRelease = struct {
    version: []const u8,
    min_sdk_version: []const u8 = "",
    fizzy_sdk_version: []const u8 = "",
    published: []const u8 = "",
    downloads: std.json.ArrayHashMap(Download) = .{},
};

/// `releases` is keyed by plugin id, one `ShardRelease` each — never an array, since a shard is
/// scoped to a single `abi_fingerprint` and therefore can only ever hold the one release a client
/// on that exact host build could install.
pub const ReleaseShard = struct {
    schema: u32 = 1,
    generated: []const u8,
    abi_fingerprint: []const u8,
    releases: std.json.ArrayHashMap(ShardRelease) = .{},
};
