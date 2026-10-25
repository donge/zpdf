//! Benchmark gate.
//!
//! Runs as part of `zig build test` (and `zig build gate`). The throughput
//! floor is deliberately conservative: it catches accidental O(n^2) work or
//! per-page document reloads, not machine-to-machine variance. Real hardware
//! extracts this fixture at >10k pages/s.

const std = @import("std");
const zpdf = @import("root.zig");
const testpdf = @import("testpdf.zig");

const PAGE_COUNT = 200;
const MIN_PAGES_PER_SEC: f64 = 100;

test "gate: 200-page throughput and text integrity" {
    const allocator = std.testing.allocator;

    const pages = try allocator.alloc([]const u8, PAGE_COUNT);
    defer allocator.free(pages);
    for (pages, 0..) |*page, i| {
        page.* = try std.fmt.allocPrint(allocator, "gate page {d} with some payload text", .{i});
    }
    defer for (pages) |page| allocator.free(page);

    const pdf = try testpdf.generateMultiPagePdf(allocator, pages);
    defer allocator.free(pdf);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    try std.testing.expectEqual(PAGE_COUNT, doc.pageCount());

    var timer = try std.time.Timer.start();
    const text = try doc.extractAllTextFast(allocator);
    defer allocator.free(text);
    const ns = timer.read();

    const pages_per_sec = @as(f64, @floatFromInt(PAGE_COUNT)) * std.time.ns_per_s /
        @as(f64, @floatFromInt(@max(ns, 1)));
    std.debug.print("\nbench gate: {d} pages in {d} ms ({d:.0} pages/s, floor {d:.0})\n", .{
        PAGE_COUNT, ns / std.time.ns_per_ms, pages_per_sec, MIN_PAGES_PER_SEC,
    });
    if (pages_per_sec < MIN_PAGES_PER_SEC) {
        std.debug.print(
            "\nbench gate: {d:.0} pages/s < {d:.0} pages/s ({d} pages in {d} ms)\n",
            .{ pages_per_sec, MIN_PAGES_PER_SEC, PAGE_COUNT, ns / std.time.ns_per_ms },
        );
        return error.BenchGateFailed;
    }

    try std.testing.expect(std.mem.indexOf(u8, text, "gate page 0 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gate page 199 ") != null);
}
