// Test for memory leaks in BEAM parser
const std = @import("std");
const beam_file = @import("src/beam_file.zig");

test "memory leak test: parse hello.beam" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        } else {
            std.debug.print("No memory leaks detected\n", .{});
        }
    }

    const allocator = gpa.allocator();

    // Parse BEAM file and ensure cleanup
    var bf = try beam_file.parseBeamFile(allocator, "hello.beam");
    defer bf.deinit();

    // Verify we got valid data
    try std.testing.expect(bf.atoms.items.len == 6);
    try std.testing.expect(bf.exports.items.len == 3);
    try std.testing.expect(bf.imports.items.len == 3);
}

test "memory leak test: parse test_complex.beam" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        } else {
            std.debug.print("No memory leaks detected\n", .{});
        }
    }

    const allocator = gpa.allocator();

    // Parse complex BEAM file
    var bf = try beam_file.parseBeamFile(allocator, "test_complex.beam");
    defer bf.deinit();

    // Verify we got valid data
    try std.testing.expect(bf.atoms.items.len == 15);
    try std.testing.expect(bf.exports.items.len == 7);
    try std.testing.expect(bf.imports.items.len == 5);
}

test "memory leak test: parse all test files" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected in test files!\n", .{});
        } else {
            std.debug.print("No memory leaks detected in test files\n", .{});
        }
    }

    const allocator = gpa.allocator();

    const test_files = [_][]const u8{
        "hello.beam",
        "test_simple.beam",
        "test_records.beam",
        "test_complex.beam",
    };

    for (test_files) |file| {
        std.debug.print("Testing {s} for memory leaks...\n", .{file});
        var bf = try beam_file.parseBeamFile(allocator, file);
        defer bf.deinit();

        // Verify basic parsing worked
        try std.testing.expect(bf.atoms.items.len > 0);
    }
}