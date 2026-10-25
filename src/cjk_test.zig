//! CJK encoding and accuracy tests.
//!
//! Synthetic PDFs cover the encodings Chinese PDFs actually use:
//!   - Type0 / Identity-H + ToUnicode CMap (the common case)
//!   - Type0 / UniGB-UCS2-H without ToUnicode (code == Unicode)
//! plus a data-driven comparison against reference text for real documents.

const std = @import("std");
const compat = @import("compat.zig");
const zpdf = @import("root.zig");
const testpdf = @import("testpdf.zig");
const testutil = @import("testutil.zig");

fn utf16beHex(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var w = compat.arrayListWriter(&out, allocator);
    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp > 0xFFFF) return error.SupplementaryNotSupported;
        try w.print("{X:0>4}", .{cp});
    }
    return out.toOwnedSlice(allocator);
}

/// Build a one-page Type0 PDF. `with_tounicode` assigns small CIDs and maps
/// them through a ToUnicode CMap; otherwise the text is written as UCS2 codes
/// (for /UniGB-UCS2-H-style predefined CMaps).
fn cidPdf(
    allocator: std.mem.Allocator,
    text: []const u8,
    encoding: []const u8,
    with_tounicode: bool,
) ![]u8 {
    var codes: std.ArrayList(u8) = .empty;
    defer codes.deinit(allocator);
    var cw = compat.arrayListWriter(&codes, allocator);

    var cmap: ?[]u8 = null;
    defer if (cmap) |c| allocator.free(c);

    if (with_tounicode) {
        var map = std.AutoHashMap(u21, u16).init(allocator);
        defer map.deinit();
        var entries: std.ArrayList(u8) = .empty;
        defer entries.deinit(allocator);
        var ew = compat.arrayListWriter(&entries, allocator);

        var next_code: u16 = 1;
        var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const code = map.get(cp) orelse blk: {
                const c = next_code;
                next_code += 1;
                try map.put(cp, c);
                var dst: [9]u8 = undefined;
                const dst_hex = if (cp <= 0xFFFF)
                    try std.fmt.bufPrint(&dst, "{X:0>4}", .{cp})
                else blk2: {
                    const v = cp - 0x10000;
                    const hi: u16 = 0xD800 + @as(u16, @intCast(v >> 10));
                    const lo: u16 = 0xDC00 + @as(u16, @intCast(v & 0x3FF));
                    break :blk2 try std.fmt.bufPrint(&dst, "{X:0>4}{X:0>4}", .{ hi, lo });
                };
                try ew.print("<{X:0>4}> <{s}>\n", .{ c, dst_hex });
                break :blk c;
            };
            try cw.print("{X:0>4}", .{code});
        }

        cmap = try std.fmt.allocPrint(
            allocator,
            "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n" ++
                "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" ++
                "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" ++
                "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n" ++
                "{d} beginbfchar\n{s}endbfchar\n" ++
                "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n",
            .{ map.count(), entries.items },
        );
    } else {
        // Codes are Unicode code points (UCS2).
        var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp > 0xFFFF) return error.SupplementaryNotSupported;
            try cw.print("{X:0>4}", .{cp});
        }
    }

    const content = try std.fmt.allocPrint(
        allocator,
        "BT\n/F1 12 Tf\n72 700 Td\n<{s}> Tj\nET\n",
        .{codes.items},
    );
    defer allocator.free(content);

    const content_obj = try std.fmt.allocPrint(
        allocator,
        "<< /Length {d} >>\nstream\n{s}\nendstream",
        .{ content.len, content },
    );
    defer allocator.free(content_obj);

    const cmap_obj = if (cmap) |c|
        try std.fmt.allocPrint(allocator, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ c.len, c })
    else
        null;
    defer if (cmap_obj) |c| allocator.free(c);

    const font = if (cmap_obj != null)
        try std.fmt.allocPrint(
            allocator,
            "<< /Type /Font /Subtype /Type0 /BaseFont /TestCJK /Encoding /{s} " ++
                "/DescendantFonts [6 0 R] /ToUnicode 7 0 R >>",
            .{encoding},
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "<< /Type /Font /Subtype /Type0 /BaseFont /TestCJK /Encoding /{s} " ++
                "/DescendantFonts [6 0 R] >>",
            .{encoding},
        );
    defer allocator.free(font);

    var objs: [7][]const u8 = undefined;
    objs[0] = "<< /Type /Catalog /Pages 2 0 R >>";
    objs[1] = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>";
    objs[2] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " ++
        "/Resources << /Font << /F1 5 0 R >> >> >>";
    objs[3] = content_obj;
    objs[4] = font;
    objs[5] = "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /TestCJK " ++
        "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> " ++
        "/W [0 [500]] >>";
    var count: usize = 6;
    if (cmap_obj) |c| {
        objs[6] = c;
        count = 7;
    }

    return testutil.buildPdf(allocator, objs[0..count]);
}

fn expectNormalized(allocator: std.mem.Allocator, got: []const u8, want: []const u8) !void {
    const g = try testutil.normalize(allocator, got);
    defer allocator.free(g);
    const w = try testutil.normalize(allocator, want);
    defer allocator.free(w);
    try std.testing.expectEqualStrings(w, g);
}

test "CJK: Identity-H with ToUnicode, mixed punctuation and digits" {
    const allocator = std.testing.allocator;
    const text = "中文编码测试：2026，ABC！";
    const pdf = try cidPdf(allocator, text, "Identity-H", true);
    defer allocator.free(pdf);
    const got = try testutil.extractOne(allocator, pdf);
    defer allocator.free(got);
    try expectNormalized(allocator, got, text);
}

test "CJK: UniGB-UCS2-H without ToUnicode" {
    const allocator = std.testing.allocator;
    const text = "张三 1300000001";
    const pdf = try cidPdf(allocator, text, "UniGB-UCS2-H", false);
    defer allocator.free(pdf);
    const got = try testutil.extractOne(allocator, pdf);
    defer allocator.free(got);
    try expectNormalized(allocator, got, text);
}

test "CJK: supplementary plane character through ToUnicode" {
    const allocator = std.testing.allocator;
    const text = "𠀀中文"; // U+20000 is outside the BMP
    const pdf = try cidPdf(allocator, text, "Identity-H", true);
    defer allocator.free(pdf);
    const got = try testutil.extractOne(allocator, pdf);
    defer allocator.free(got);
    try expectNormalized(allocator, got, text);
}

test "CJK: generated CID font PDF extracts mixed text" {
    const allocator = std.testing.allocator;
    const pdf = try testpdf.generateCIDFontPdf(allocator);
    defer allocator.free(pdf);
    const got = try testutil.extractOne(allocator, pdf);
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\u{4E2D}") != null);
}

// Optional real-document accuracy check.
//
// Create `testdata/cjk_regression.tsv` with one `pdf<TAB>reference.txt` per
// line (reference text from human transcription, pdftotext, or another
// trusted extractor). The test skips when the file is absent.
test "CJK corpus: character accuracy against reference text" {
    const allocator = std.testing.allocator;
    const list = compat.readFileAllocAlignedCwd(
        allocator,
        "testdata/cjk_regression.tsv",
        .fromByteUnits(1),
    ) catch return error.SkipZigTest;
    defer allocator.free(list);

    var docs: usize = 0;
    var f1_sum: f64 = 0;
    var recall_sum: f64 = 0;
    var failures: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, list, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var parts = std.mem.splitScalar(u8, line, '\t');
        const pdf_path = parts.next() orelse continue;
        const ref_path = parts.next() orelse continue;

        const ref_raw = compat.readFileAllocAlignedCwd(allocator, ref_path, .fromByteUnits(1)) catch continue;
        defer allocator.free(ref_raw);

        const doc = zpdf.Document.open(allocator, pdf_path) catch {
            failures += 1;
            continue;
        };
        defer doc.close();
        const got = doc.extractAllTextStructured(allocator) catch {
            failures += 1;
            continue;
        };
        defer allocator.free(got);

        const g = try testutil.normalize(allocator, got);
        defer allocator.free(g);
        const r = try testutil.normalize(allocator, ref_raw);
        defer allocator.free(r);

        const m = try testutil.char4Match(allocator, r, g);
        docs += 1;
        f1_sum += m.f1;
        recall_sum += m.recall;
        std.debug.print("{s}: recall={d:.4} F1={d:.4} chars got={d} ref={d}\n", .{ pdf_path, m.recall, m.f1, g.len, r.len });
        if (m.recall < 0.95) failures += 1;
    }

    if (docs == 0) return error.SkipZigTest;
    const mean_f1 = f1_sum / @as(f64, @floatFromInt(docs));
    const mean_recall = recall_sum / @as(f64, @floatFromInt(docs));
    std.debug.print("CJK corpus: {d} docs, mean recall={d:.4}, mean F1={d:.4}, failures={d}\n", .{
        docs, mean_recall, mean_f1, failures,
    });
    try std.testing.expect(failures == 0);
    try std.testing.expect(mean_recall >= 0.98);
}
