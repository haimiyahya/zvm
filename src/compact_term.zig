// src/compact_term.zig - Compact Term Encoding for BEAM instruction arguments
// Based on BEAM Book specification

const std = @import("std");

// Tag values (3 bits, low bits of first byte)
pub const Tag = enum(u3) {
    literal = 0b000,  // Index into literal table
    integer = 0b001,  // Integer value
    atom = 0b010,     // Atom index (minus one, 0 means NIL)
    x_reg = 0b011,    // X register
    y_reg = 0b100,    // Y register
    label = 0b101,    // Label
    character = 0b110, // Character value
    extended = 0b111,  // Extended encoding
};

// Extended tag values (when tag = 0b111)
pub const ExtendedTag = enum(u4) {
    unused = 0b0000,      // Not used after R16B
    list = 0b0010,        // List (select_val)
    fp_reg = 0b0100,      // Floating point register
    alloc_list = 0b0110,  // Allocation list
    literal_ext = 0b1000, // Extended literal
    reg_hint = 0b1010,    // Register with type hint (OTP 25+)
};

pub const CompactTerm = struct {
    tag: Tag,
    value: u64,

    pub fn format(self: CompactTerm, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.tag) {
            .literal => try std.fmt.allocPrint(allocator, "literal[{d}]", .{self.value}),
            .integer => try std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @bitCast(self.value))}),
            .atom => if (self.value == 0) try std.fmt.allocPrint(allocator, "NIL", .{}) else try std.fmt.allocPrint(allocator, "atom[{d}]", .{self.value - 1}),
            .x_reg => try std.fmt.allocPrint(allocator, "x({d})", .{self.value}),
            .y_reg => try std.fmt.allocPrint(allocator, "y({d})", .{self.value}),
            .label => try std.fmt.allocPrint(allocator, "label_{d}", .{self.value}),
            .character => try std.fmt.allocPrint(allocator, "'{u}'", .{@as(u8, @intCast(self.value))}),
            .extended => try std.fmt.allocPrint(allocator, "extended[{d}]", .{self.value}),
        };
    }
};

pub const CompactDecoder = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn eof(self: *const CompactDecoder) bool {
        return self.pos >= self.data.len;
    }

    pub fn readByte(self: *CompactDecoder) !u8 {
        if (self.pos >= self.data.len) return error.Truncated;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn decode(self: *CompactDecoder) !CompactTerm {
        if (self.eof()) return error.Truncated;

        const first_byte = try self.readByte();
        const tag: Tag = @enumFromInt(first_byte & 0b111);

        // Special case: extended tag (tag=7) needs different handling
        if (tag == .extended) {
            // For extended tags, read the next byte as the actual value
            // BEAM extended encoding: first byte has tag=7, next byte has value
            if (self.eof()) return error.Truncated;
            const next_byte = try self.readByte();
            return .{ .tag = tag, .value = next_byte };
        }

        // Small value encoding (< 16): bit 3 is 0
        // Format: bits 7-4 = value, bit 3 = 0, bits 2-0 = tag
        if ((first_byte & 0b1000) == 0) {
            const value: u64 = first_byte >> 4;
            return .{ .tag = tag, .value = value };
        }

        // Medium value encoding (< 2048): bits 4-5 are 01
        // Format: bits 7-6 = extended value, bits 5-4 = 01, bit 3 = 1, bits 2-0 = tag
        if ((first_byte & 0b110000) == 0b10000) {
            if (self.eof()) return error.Truncated;
            const second_byte = try self.readByte();
            const high_bits: u64 = (first_byte & 0b11100000) >> 5;
            const value: u64 = (high_bits << 8) | second_byte;
            return .{ .tag = tag, .value = value };
        }

        // Extended encoding (2-8 bytes): bits 4-5 are 11
        // Format: bits 7-5 = byte_count-2, bits 5-4 = 11, bits 2-0 = tag
        if ((first_byte & 0b111000) == 0b110000) {
            const byte_count = ((first_byte & 0b11100000) >> 5) + 2;
            if (self.pos + byte_count > self.data.len) return error.Truncated;

            var value: u64 = 0;
            for (0..byte_count) |_| {
                const b = try self.readByte();
                value = (value << 8) | b;
            }
            return .{ .tag = tag, .value = value };
        }

        // Very large encoding (> 8 bytes)
        if ((first_byte & 0b111111) == 0b111110) {
            // For Phase 1, just report as extended
            return .{ .tag = .extended, .value = 0 };
        }

        return error.InvalidEncoding;
    }
};

test "decode small integer" {
    // Format: bits 7-4 = value, bit 3 = 0, bits 2-0 = tag
    // value=9 (1001), tag=001 (integer), bit 3 = 0
    const data = [_]u8{0b10010001}; // 145: tag=001, value=9
    var decoder = CompactDecoder{ .data = &data };
    const term = try decoder.decode();
    try std.testing.expectEqual(Tag.integer, term.tag);
    try std.testing.expectEqual(@as(u64, 9), term.value);
}

test "decode small x register" {
    // Format: bits 7-4 = value, bit 3 = 0, bits 2-0 = tag
    // value=3 (0011), tag=011 (x_reg), bit 3 = 0
    const data = [_]u8{0b00110011}; // 51: tag=011, value=3
    var decoder = CompactDecoder{ .data = &data };
    const term = try decoder.decode();
    try std.testing.expectEqual(Tag.x_reg, term.tag);
    try std.testing.expectEqual(@as(u64, 3), term.value);
}

test "decode NIL (atom 0)" {
    const data = [_]u8{0b00000010}; // tag=010 (atom), value=0
    var decoder = CompactDecoder{ .data = &data };
    const term = try decoder.decode();
    try std.testing.expectEqual(Tag.atom, term.tag);
    try std.testing.expectEqual(@as(u64, 0), term.value);
}