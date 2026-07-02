//! Wall-clock date formatting (`YYYY-MM-DD`), used for `plugins.date_added` /
//! `plugins.last_ok_at`. `std.Io.Clock.real` counts seconds since the Unix epoch (see
//! `std.Io.Clock` doc comment), so this needs no libc/OS-specific date API.
const std = @import("std");

/// Today's date (UTC) as `YYYY-MM-DD`. Caller owns the returned slice.
pub fn todayIso(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const timestamp = std.Io.Clock.real.now(io);
    const seconds: u64 = @intCast(@divFloor(timestamp.nanoseconds, std.time.ns_per_s));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
    });
}

/// Current UTC instant as `YYYY-MM-DDTHH:MM:SSZ` — used for `catalog/*.json`'s `generated` field.
pub fn nowIso8601(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const timestamp = std.Io.Clock.real.now(io);
    const seconds: u64 = @intCast(@divFloor(timestamp.nanoseconds, std.time.ns_per_s));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

test "todayIso formats a plausible date" {
    // We don't control wall-clock time in a test, so just sanity-check the shape.
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const date = try todayIso(std.testing.allocator, io);
    defer std.testing.allocator.free(date);

    try std.testing.expectEqual(@as(usize, 10), date.len);
    try std.testing.expectEqual(@as(u8, '-'), date[4]);
    try std.testing.expectEqual(@as(u8, '-'), date[7]);
}

test "nowIso8601 formats a plausible timestamp" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const stamp = try nowIso8601(std.testing.allocator, io);
    defer std.testing.allocator.free(stamp);

    try std.testing.expectEqual(@as(usize, 20), stamp.len);
    try std.testing.expectEqual(@as(u8, 'T'), stamp[10]);
    try std.testing.expectEqual(@as(u8, 'Z'), stamp[19]);
}
