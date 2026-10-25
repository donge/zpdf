//! Image extraction tests (OCR input).

const std = @import("std");
const compat = @import("compat.zig");
const zpdf = @import("root.zig");
const testutil = @import("testutil.zig");
const testpdf = @import("testpdf.zig");

fn streamObj(allocator: std.mem.Allocator, dict: []const u8, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var w = compat.arrayListWriter(&out, allocator);
    try w.print("<< {s} /Length {d} >>\nstream\n", .{ dict, data.len });
    try w.writeAll(data);
    try w.writeAll("\nendstream");
    return out.toOwnedSlice(allocator);
}

fn rgbImage(allocator: std.mem.Allocator, w: u32, h: u32, mask: bool) ![]u8 {
    const pixels = try allocator.alloc(u8, @as(usize, w) * h * 3);
    defer allocator.free(pixels);
    for (pixels, 0..) |*p, i| p.* = @intCast(i % 251);
    const dict = if (mask)
        try std.fmt.allocPrint(allocator, "/Type /XObject /Subtype /Image /Width {d} /Height {d} /ImageMask true /BitsPerComponent 1", .{ w, h })
    else
        try std.fmt.allocPrint(allocator, "/Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace /DeviceRGB /BitsPerComponent 8", .{ w, h });
    defer allocator.free(dict);
    return streamObj(allocator, dict, pixels);
}

fn pageWithImage(allocator: std.mem.Allocator, image: []const u8, content: []const u8) ![]u8 {
    const content_obj = try streamObj(allocator, "", content);
    defer allocator.free(content_obj);
    const objs = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " ++
            "/Resources << /XObject << /Im1 5 0 R >> >> >>",
        content_obj,
        image,
    };
    return testutil.buildPdf(allocator, &objs);
}

test "images: unfiltered DeviceRGB -> rgb24" {
    const allocator = std.testing.allocator;
    const image = try rgbImage(allocator, 128, 96, false);
    defer allocator.free(image);
    const pdf = try pageWithImage(allocator, image, "q 100 0 0 100 50 50 cm /Im1 Do Q");
    defer allocator.free(pdf);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    const imgs = try doc.extractPageImages(0, allocator);
    defer zpdf.Document.freePageImages(allocator, imgs);

    try std.testing.expectEqual(@as(usize, 1), imgs.len);
    try std.testing.expectEqual(zpdf.Document.ImageFormat.rgb24, imgs[0].format);
    try std.testing.expectEqual(@as(u32, 128), imgs[0].width);
    try std.testing.expectEqual(@as(u32, 96), imgs[0].height);
    try std.testing.expectEqual(@as(usize, 128 * 96 * 3), imgs[0].data.len);
    try std.testing.expectEqual(@as(u8, 0), imgs[0].data[0]);
    try std.testing.expectEqual(@as(u8, 1), imgs[0].data[1]);
}

test "images: DCT passthrough keeps JPEG bytes" {
    const allocator = std.testing.allocator;
    const jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 0xFF, 0xD9 };
    const img = try streamObj(
        allocator,
        "/Type /XObject /Subtype /Image /Width 200 /Height 100 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode",
        &jpeg,
    );
    defer allocator.free(img);
    const pdf = try pageWithImage(allocator, img, "q 200 0 0 100 0 0 cm /Im1 Do Q");
    defer allocator.free(pdf);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    const imgs = try doc.extractPageImages(0, allocator);
    defer zpdf.Document.freePageImages(allocator, imgs);
    try std.testing.expectEqual(@as(usize, 1), imgs.len);
    try std.testing.expectEqual(zpdf.Document.ImageFormat.jpeg, imgs[0].format);
    try std.testing.expectEqualSlices(u8, &jpeg, imgs[0].data);
}

test "images: CCITT passthrough keeps parameters" {
    const allocator = std.testing.allocator;
    const raw = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const img = try streamObj(
        allocator,
        "/Type /XObject /Subtype /Image /Width 1728 /Height 2200 /ColorSpace /DeviceGray " ++
            "/BitsPerComponent 1 /Filter /CCITTFaxDecode " ++
            "/DecodeParms << /K -1 /Columns 1728 /Rows 2200 /BlackIs1 true >>",
        &raw,
    );
    defer allocator.free(img);
    const pdf = try pageWithImage(allocator, img, "q 612 0 0 792 0 0 cm /Im1 Do Q");
    defer allocator.free(pdf);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    const imgs = try doc.extractPageImages(0, allocator);
    defer zpdf.Document.freePageImages(allocator, imgs);
    try std.testing.expectEqual(@as(usize, 1), imgs.len);
    try std.testing.expectEqual(zpdf.Document.ImageFormat.ccitt, imgs[0].format);
    try std.testing.expectEqual(@as(i32, -1), imgs[0].ccitt_k);
    try std.testing.expect(imgs[0].black_is_1);
    try std.testing.expectEqualSlices(u8, &raw, imgs[0].data);
}

test "images: ImageMask and tiny images are skipped" {
    const allocator = std.testing.allocator;
    const masked = try rgbImage(allocator, 128, 128, true);
    defer allocator.free(masked);
    const pdf = try pageWithImage(allocator, masked, "q 100 0 0 100 50 50 cm /Im1 Do Q");
    defer allocator.free(pdf);
    const doc = try zpdf.Document.openFromMemory(allocator, pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    const imgs = try doc.extractPageImages(0, allocator);
    defer zpdf.Document.freePageImages(allocator, imgs);
    try std.testing.expectEqual(@as(usize, 0), imgs.len);

    const tiny = try rgbImage(allocator, 32, 32, false);
    defer allocator.free(tiny);
    const pdf2 = try pageWithImage(allocator, tiny, "q 10 0 0 10 50 50 cm /Im1 Do Q");
    defer allocator.free(pdf2);
    const doc2 = try zpdf.Document.openFromMemory(allocator, pdf2, zpdf.ErrorConfig.default());
    defer doc2.close();
    const imgs2 = try doc2.extractPageImages(0, allocator);
    defer zpdf.Document.freePageImages(allocator, imgs2);
    try std.testing.expectEqual(@as(usize, 0), imgs2.len);
}

test "images: nested form with indirect resources" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(u8, 100 * 100 * 3);
    defer allocator.free(pixels);
    @memset(pixels, 200);
    const image = try streamObj(
        allocator,
        "/Type /XObject /Subtype /Image /Width 100 /Height 100 /ColorSpace /DeviceRGB /BitsPerComponent 8",
        pixels,
    );
    defer allocator.free(image);

    const form_content = "q 300 0 0 300 0 0 cm /Im1 Do Q";
    const form_obj = try streamObj(
        allocator,
        "/Type /XObject /Subtype /Form /BBox [0 0 300 300] /Resources 6 0 R",
        form_content,
    );
    defer allocator.free(form_obj);
    const page_content = "q 1 0 0 1 0 0 cm /Fm1 Do Q";
    const page_content_obj = try streamObj(allocator, "", page_content);
    defer allocator.free(page_content_obj);

    const objs = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " ++
            "/Resources << /XObject << /Fm1 5 0 R >> >> >>",
        page_content_obj,
        form_obj,
        "<< /XObject << /Im1 7 0 R >> >>",
        image,
    };
    const pdf = try testutil.buildPdf(allocator, &objs);
    defer allocator.free(pdf);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    const imgs = try doc.extractPageImages(0, allocator);
    defer zpdf.Document.freePageImages(allocator, imgs);
    try std.testing.expectEqual(@as(usize, 1), imgs.len);
    try std.testing.expectEqual(zpdf.Document.ImageFormat.rgb24, imgs[0].format);
    try std.testing.expectEqual(@as(usize, 100 * 100 * 3), imgs[0].data.len);
}

test "images: indirect DecodeParms predictor is applied" {
    const allocator = std.testing.allocator;
    // 64x64 DeviceRGB, solid (10,20,30), PNG Sub predictor (filter 1), zlib.
    const compressed = [_]u8{
        120, 218, 237, 207, 33, 13,  0,  0,  8,   0,   48, 176, 104, 52, 253, 99,
        18,  1,   205, 246, 55, 120, 86, 79, 124, 150, 2,  2,   2,   2,  2,   2,
        2,   2,   2,   2,   2,  2,   2,  2,  2,   2,   2,  2,   2,   2,  2,   2,
        2,   2,   2,   2,   2,  2,   2,  2,  2,   2,   2,  2,   2,   2,  2,   2,
        2,   2,   2,   2,   2,  2,   2,  2,  2,   2,   2,  2,   2,   2,  151, 5,
        202, 187, 15,  65,
    };
    const image = try streamObj(
        allocator,
        "/Type /XObject /Subtype /Image /Width 64 /Height 64 /ColorSpace /DeviceRGB " ++
            "/BitsPerComponent 8 /Filter /FlateDecode /DecodeParms 6 0 R",
        &compressed,
    );
    defer allocator.free(image);
    const content = "q 100 0 0 100 10 10 cm /Im1 Do Q";
    const content_obj = try streamObj(allocator, "", content);
    defer allocator.free(content_obj);

    const objs = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " ++
            "/Resources << /XObject << /Im1 5 0 R >> >> >>",
        content_obj,
        image,
        "<< /Predictor 15 /Columns 64 /Colors 3 /BitsPerComponent 8 >>",
    };
    const pdf = try testutil.buildPdf(allocator, &objs);
    defer allocator.free(pdf);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    const imgs = try doc.extractPageImages(0, allocator);
    defer zpdf.Document.freePageImages(allocator, imgs);
    try std.testing.expectEqual(@as(usize, 1), imgs.len);
    try std.testing.expectEqual(zpdf.Document.ImageFormat.rgb24, imgs[0].format);
    try std.testing.expectEqual(@as(usize, 64 * 64 * 3), imgs[0].data.len);
    try std.testing.expectEqual(@as(u8, 10), imgs[0].data[0]);
    try std.testing.expectEqual(@as(u8, 20), imgs[0].data[1]);
    try std.testing.expectEqual(@as(u8, 30), imgs[0].data[2]);
}

test "images: openFromMemoryCopied frees its aligned copy" {
    const allocator = std.testing.allocator;
    const pdf = try testpdf.generateMinimalPdf(allocator, "aligned");
    defer allocator.free(pdf);
    const doc = try zpdf.Document.openFromMemoryCopied(allocator, pdf, zpdf.ErrorConfig.default());
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
    doc.close();
}
