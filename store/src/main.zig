//! CLI entry point for the plugin store's registry tool: `ingest` (fetch author manifests into
//! `registry.db`), `export` (dump the DB to the static `catalog/` files Fizzy fetches), and
//! `validate` (PR-time structural check, no network/DB). See PLAN.md for the phased rollout —
//! this binary replaces `scripts/aggregate.py`.
const std = @import("std");

const db = @import("db.zig");
const ingest = @import("ingest.zig");
const export_cmd = @import("export_cmd.zig");
const validate = @import("validate.zig");
const registry_entry = @import("registry_entry.zig");
const manifest = @import("manifest.zig");
const fetch = @import("fetch.zig");
const time_fmt = @import("time_fmt.zig");
const catalog = @import("catalog.zig");
const fetch_manifests = @import("fetch_manifests.zig");

const usage =
    \\usage: store <command> [args]
    \\
    \\commands:
    \\  ingest    fetch registry/<id>.json manifests into registry.db
    \\  export    dump registry.db into plugins/catalog/ (summary.json + per-fingerprint shards)
    \\  validate  structural check of registry/<id>.json (no network, no db)
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return 1;
    }

    const command = args[1];
    const rest = args[2..];

    const result = if (std.mem.eql(u8, command, "ingest"))
        ingest.run(allocator, init.io, rest)
    else if (std.mem.eql(u8, command, "export"))
        export_cmd.run(allocator, init.io, rest)
    else if (std.mem.eql(u8, command, "validate"))
        validate.run(allocator, init.io, rest)
    else {
        std.debug.print("unknown command '{s}'\n\n{s}", .{ command, usage });
        return 1;
    };

    result catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

// `pub fn main` is never called in a test build (the test runner supplies its own entry point),
// so an import only reached through `main()`'s body — like `ingest`/`export_cmd`/`validate` below
// — would otherwise never be analyzed, silently dropping its `test` blocks from `zig build test`.
// Referencing every module here forces each file into the test build regardless.
test {
    _ = db;
    _ = ingest;
    _ = export_cmd;
    _ = validate;
    _ = registry_entry;
    _ = manifest;
    _ = fetch;
    _ = time_fmt;
    _ = catalog;
    _ = fetch_manifests;
}
