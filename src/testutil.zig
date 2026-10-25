//! Shared helpers for regression/CJK tests: build tiny PDFs, extract text,
//! compare against a reference.

const std = @import("std");
const compat = @import("compat.zig");
const zpdf = @import("root.zig");
const unorm = @import("unicode_norm.zig");

pub fn buildPdf(allocator: std.mem.Allocator, objs: []const []const u8) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var w = compat.arrayListWriter(&pdf, allocator);

    try w.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");
    const offsets = try allocator.alloc(usize, objs.len);
    defer allocator.free(offsets);

    for (objs, 0..) |body, i| {
        offsets[i] = pdf.items.len;
        try w.print("{d} 0 obj\n", .{i + 1});
        try w.writeAll(body);
        try w.writeAll("\nendobj\n");
    }

    const xref_offset = pdf.items.len;
    try w.writeAll("xref\n");
    try w.print("0 {d}\n", .{objs.len + 1});
    try w.writeAll("0000000000 65535 f \n");
    for (offsets) |off| {
        try w.print("{d:0>10} 00000 n \n", .{off});
    }
    try w.writeAll("trailer\n");
    try w.print("<< /Size {d} /Root 1 0 R >>\n", .{objs.len + 1});
    try w.print("startxref\n{d}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

pub fn extractOne(allocator: std.mem.Allocator, pdf: []const u8) ![]u8 {
    const doc = try zpdf.Document.openFromMemory(allocator, pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try doc.extractText(0, compat.arrayListWriter(&out, allocator));
    return out.toOwnedSlice(allocator);
}

/// Remove whitespace (including U+3000) so that line wrapping does not affect
/// the comparison.
pub fn normalize(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var view = std.unicode.Utf8View.init(s) catch {
        try out.appendSlice(allocator, s);
        return out.toOwnedSlice(allocator);
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == ' ' or cp == '\n' or cp == '\r' or cp == '\t' or cp == 0x3000) continue;
        const c: u21 = @intCast(cp);
        if (unorm.ignorable(c)) continue;
        if (unorm.lookup(c)) |e| {
            for (e.repl[0..e.len]) |r| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(r, &buf) catch continue;
                try out.appendSlice(allocator, buf[0..n]);
            }
            continue;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &buf) catch continue;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

pub const Match = struct { f1: f64, recall: f64 };

/// Character 4-gram multiset comparison. `recall` is the fraction of the
/// reference grams present in the prediction (robust when the reference is
/// incomplete); `f1` also penalises extra text.
pub fn char4Match(allocator: std.mem.Allocator, ref: []const u8, pred: []const u8) !Match {
    if (ref.len < 4 or pred.len < 4) {
        const eq = std.mem.eql(u8, ref, pred);
        return .{ .f1 = if (eq) 1 else 0, .recall = if (eq) 1 else 0 };
    }
    const Counts = std.StringHashMap(u32);
    var a = Counts.init(allocator);
    defer a.deinit();
    var b = Counts.init(allocator);
    defer b.deinit();
    var i: usize = 0;
    while (i + 4 <= ref.len) : (i += 1) {
        const gop = try a.getOrPut(ref[i..][0..4]);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    i = 0;
    while (i + 4 <= pred.len) : (i += 1) {
        const gop = try b.getOrPut(pred[i..][0..4]);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    var inter: u64 = 0;
    var it = a.iterator();
    while (it.next()) |e| {
        if (b.get(e.key_ptr.*)) |bv| inter += @min(e.value_ptr.*, bv);
    }
    var na: u64 = 0;
    var ia = a.valueIterator();
    while (ia.next()) |v| na += v.*;
    var nb: u64 = 0;
    var ib = b.valueIterator();
    while (ib.next()) |v| nb += v.*;
    if (na == 0 or nb == 0) return .{ .f1 = 0, .recall = 0 };
    const prec = @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(nb));
    const rec = @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(na));
    return .{
        .f1 = if (prec + rec == 0) 0 else 2 * prec * rec / (prec + rec),
        .recall = rec,
    };
}
