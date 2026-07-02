//! GET a manifest's bytes over HTTP(S), or read them straight off disk for a `file://` URL —
//! `aggregate.py` supported `file://` for local testing (see the plugins repo README) and it's
//! worth keeping: it lets `store ingest` be exercised against a fixture manifest with no network
//! and no test server. `file://` handling is POSIX-only (this tool never builds for Windows —
//! see `build.zig`), matching how `readFileAlloc` resolves an absolute path here.
const std = @import("std");

pub const FetchError = error{
    HttpStatus,
} || std.mem.Allocator.Error;

const file_scheme = "file://";

/// Fetch `url`'s bytes. Caller owns the returned slice.
pub fn fetchBytes(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, url, file_scheme)) {
        const path = url[file_scheme.len..];
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    }
    return fetchHttp(allocator, io, url);
}

fn fetchHttp(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) return FetchError.HttpStatus;

    return body.toOwnedSlice();
}
