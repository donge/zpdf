//! Regression tests for the defects fixed in this fork.
//!
//! Each test is a minimal PDF that reproduces one real-world failure mode:
//! xref recovery, Form XObject fonts, Unicode mapping and CTM-based lines.

const std = @import("std");
const compat = @import("compat.zig");
const zpdf = @import("root.zig");
const testpdf = @import("testpdf.zig");

fn buildPdf(allocator: std.mem.Allocator, objs: []const []const u8) ![]u8 {
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

fn extractOne(allocator: std.mem.Allocator, pdf: []const u8) ![]u8 {
    const doc = try zpdf.Document.openFromMemory(allocator, pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try doc.extractText(0, compat.arrayListWriter(&out, allocator));
    return out.toOwnedSlice(allocator);
}

test "xref: CRLF before xref keyword and generation 65536" {
    const allocator = std.testing.allocator;
    const base = try testpdf.generateMinimalPdf(allocator, "XrefFix");
    defer allocator.free(base);

    const sx = std.mem.lastIndexOf(u8, base, "startxref\n") orelse return error.NoStartXref;
    const num_start = sx + "startxref\n".len;
    var num_end = num_start;
    while (base[num_end] >= '0' and base[num_end] <= '9') num_end += 1;
    const old_offset = try std.fmt.parseInt(usize, base[num_start..num_end], 10);
    const new_offset = old_offset + 2;

    var broken: std.ArrayList(u8) = .empty;
    defer broken.deinit(allocator);
    try broken.appendSlice(allocator, base[0..old_offset]);
    try broken.appendSlice(allocator, "\r\n");
    try broken.appendSlice(allocator, base[old_offset..]);

    // startxref moved by 2 bytes; rewrite the value in place (same width here).
    const nsx = std.mem.lastIndexOf(u8, broken.items, "startxref\n").? + "startxref\n".len;
    var ns_end = nsx;
    while (broken.items[ns_end] >= '0' and broken.items[ns_end] <= '9') ns_end += 1;
    var buf: [20]u8 = undefined;
    const digits = try std.fmt.bufPrint(&buf, "{d}", .{new_offset});
    try std.testing.expectEqual(ns_end - nsx, digits.len);
    @memcpy(broken.items[nsx..ns_end], digits);

    // The free-list head is commonly written with generation 65536.
    const entry = std.mem.indexOf(u8, broken.items, " 65535 f").?;
    @memcpy(broken.items[entry + 1 .. entry + 6], "65536");

    const text = try extractOne(allocator, broken.items);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "XrefFix") != null);
}

test "Form XObject: follow Do and load fonts from the form resources" {
    const allocator = std.testing.allocator;
    const form_content = "BT /F1 12 Tf 72 700 Td (FormOnly) Tj ET";
    const form = try std.fmt.allocPrint(
        allocator,
        "<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] " ++
            "/Resources << /Font << /F1 6 0 R >> >> /Length {d} >>\nstream\n{s}\nendstream",
        .{ form_content.len, form_content },
    );
    defer allocator.free(form);

    const objs = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " ++
            "/Resources << /XObject << /Fm1 5 0 R >> >> >>",
        "<< /Length 7 >>\nstream\n/Fm1 Do\nendstream",
        form,
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    };

    const pdf = try buildPdf(allocator, &objs);
    defer allocator.free(pdf);
    const text = try extractOne(allocator, pdf);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "FormOnly") != null);
}

test "unicode: Kangxi radicals are mapped to unified ideographs" {
    const allocator = std.testing.allocator;
    const cmap =
        "/CIDInit /ProcSet findresource begin\n" ++
        "12 dict begin\nbegincmap\n" ++
        "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" ++
        "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" ++
        "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n" ++
        "1 beginbfchar\n<41> <2F63>\nendbfchar\n" ++
        "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n";
    const cmap_obj = try std.fmt.allocPrint(
        allocator,
        "<< /Length {d} >>\nstream\n{s}\nendstream",
        .{ cmap.len, cmap },
    );
    defer allocator.free(cmap_obj);
    const content = "BT /F1 12 Tf 72 700 Td (A) Tj ET";
    const content_obj = try std.fmt.allocPrint(
        allocator,
        "<< /Length {d} >>\nstream\n{s}\nendstream",
        .{ content.len, content },
    );
    defer allocator.free(content_obj);

    const objs = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " ++
            "/Resources << /Font << /F1 5 0 R >> >> >>",
        content_obj,
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
        cmap_obj,
    };

    const pdf = try buildPdf(allocator, &objs);
    defer allocator.free(pdf);
    const text = try extractOne(allocator, pdf);
    defer allocator.free(text);
    // U+2F63 (Kangxi radical) -> U+751F (生), not the radical itself.
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{751F}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2F63}") == null);
}

test "layout: cm-positioned text produces separate lines" {
    const allocator = std.testing.allocator;
    const content =
        "q 1 0 0 1 72 700 cm BT /F1 12 Tf 0 0 Td (LineOne) Tj ET Q\n" ++
        "q 1 0 0 1 72 650 cm BT /F1 12 Tf 0 0 Td (LineTwo) Tj ET Q";
    const content_obj = try std.fmt.allocPrint(
        allocator,
        "<< /Length {d} >>\nstream\n{s}\nendstream",
        .{ content.len, content },
    );
    defer allocator.free(content_obj);

    const objs = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " ++
            "/Resources << /Font << /F1 5 0 R >> >> >>",
        content_obj,
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    };

    const pdf = try buildPdf(allocator, &objs);
    defer allocator.free(pdf);
    const text = try extractOne(allocator, pdf);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "LineOne\nLineTwo") != null);
}

test "unicode table: zero-width droppped, fullwidth alnum folded" {
    const unorm = @import("unicode_norm.zig");
    try std.testing.expect(unorm.ignorable(0x200B));
    try std.testing.expect(unorm.ignorable(0xFEFF));
    const e = unorm.lookup(0xFF21).?;
    try std.testing.expectEqual(@as(u21, 'A'), e.repl[0]);
    const radical = unorm.lookup(0x2F63).?;
    try std.testing.expectEqual(@as(u21, 0x751F), radical.repl[0]);
}

test "Form XObject: same font name in two forms does not collide" {
    const allocator = std.testing.allocator;
    const form1_content = "BT /F1 12 Tf 10 10 Td (AAAA) Tj ET";
    const form2_content = "BT /F1 12 Tf 10 100 Td (AAAA) Tj ET";
    const form1 = try std.fmt.allocPrint(
        allocator,
        "<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] " ++
            "/Resources << /Font << /F1 6 0 R >> >> /Length {d} >>\nstream\n{s}\nendstream",
        .{ form1_content.len, form1_content },
    );
    defer allocator.free(form1);
    const form2 = try std.fmt.allocPrint(
        allocator,
        "<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] " ++
            "/Resources << /Font << /F1 7 0 R >> >> /Length {d} >>\nstream\n{s}\nendstream",
        .{ form2_content.len, form2_content },
    );
    defer allocator.free(form2);

    const cmap =
        "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n" ++
        "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" ++
        "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" ++
        "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n" ++
        "1 beginbfchar\n<41> <42>\nendbfchar\n" ++
        "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n";
    const cmap_obj = try std.fmt.allocPrint(
        allocator,
        "<< /Length {d} >>\nstream\n{s}\nendstream",
        .{ cmap.len, cmap },
    );
    defer allocator.free(cmap_obj);

    const objs = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " ++
            "/Resources << /XObject << /Fm1 5 0 R /Fm2 8 0 R >> >> >>",
        "<< /Length 15 >>\nstream\n/Fm1 Do /Fm2 Do\nendstream",
        form1,
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 9 0 R >>",
        form2,
        cmap_obj,
    };

    const pdf = try buildPdf(allocator, &objs);
    defer allocator.free(pdf);
    const text = try extractOne(allocator, pdf);
    defer allocator.free(text);
    // Form 1 keeps the plain WinAnsi mapping, form 2 maps A -> B.
    try std.testing.expect(std.mem.indexOf(u8, text, "AAAA") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "BBBB") != null);
}
