// src/term.zig - BEAM 64-bit term representation
// Target: OTP 26/27/28 compatible layout
// Reference: erts/emulator/beam/erl_term.h, The BEAM Book

const std = @import("std");

// ============================================================================
// Tag Definitions - BEAM 64-bit Layout
// ============================================================================

// BEAM uses low 4 bits for immediates, low 2 bits for primary tags
pub const Tag = struct {
    // Immediate term tags (low 4 bits)
    pub const TAG_MASK: u64 = 0xF;

    // Small integer: xxx...xxx 0011
    pub const SMALL_INT_TAG: u64 = 0x3;

    // Atom: xxx...xxx 1011 (19-bit index in OTP 26+)
    pub const ATOM_TAG: u64 = 0xB;

    // PID: xxx...xxx 1101
    pub const PID_TAG: u64 = 0xD;

    // Port: xxx...xxx 1110
    pub const PORT_TAG: u64 = 0xE;

    // Reference: xxx...xxx 1111
    pub const REF_TAG: u64 = 0xF;

    // Literal pointer (special tag for constant pool)
    pub const LITERAL_TAG: u64 = 0x2;

    // Boxed pointer (low 2 bits are 00)
    pub const BOXED_TAG: u64 = 0x0;
};

// Header tags for boxed terms (6 bits in header)
pub const HeaderTag = enum(u6) {
    // Primary header tags
    tuple = 0,
    big_int = 3,
    ref = 4,
    fun = 5,
    external_fun = 6,
    binary = 8,
    map = 9,

    // Special headers
    heap_binary = 10,
    double_big = 11,
    ref_c_binary = 12,
    proc_bin = 13,

    // Compatibility
    nil = 14, // Empty list []
    list = 15, // Cons cell
};

// ============================================================================
// Term Type - Main Term Representation
// ============================================================================

pub const Term = struct {
    value: u64,

    // =========================================================================
    // Construction Functions
    // =========================================================================

    pub inline fn fromRaw(raw: u64) Term {
        return .{ .value = raw };
    }

    pub inline fn toRaw(self: Term) u64 {
        return self.value;
    }

    // Small integer: 60-bit signed payload << 4 | 0b0011
    pub inline fn makeSmallInt(value: i64) Term {
        // Ensure value fits in 60 bits: -2^59 to 2^59-1
        std.debug.assert(value >= -(1 << 59) and value < (1 << 59));
        const unsigned: u64 = @bitCast(value);
        return .{ .value = (unsigned << 4) | Tag.SMALL_INT_TAG };
    }

    // Atom: 19-bit index << 4 | 0b1011
    pub inline fn makeAtom(index: u32) Term {
        std.debug.assert(index < (1 << 19)); // 19-bit index
        return .{ .value = (@as(u64, index) << 4) | Tag.ATOM_TAG };
    }

    // Boxed pointer: pointer value (must be 8-byte aligned, low 2 bits 00)
    pub inline fn makeBoxed(ptr: *anyopaque) Term {
        const addr = @intFromPtr(ptr);
        std.debug.assert(addr & 0b11 == 0); // Must be aligned
        return .{ .value = addr | Tag.BOXED_TAG };
    }

    // Literal pointer for constant pool
    pub inline fn makeLiteral(index: u32) Term {
        return .{ .value = (@as(u64, index) << 4) | Tag.LITERAL_TAG };
    }

    // NIL (empty list)
    pub const NIL: Term = .{ .value = (@as(u64, 0) << 4) | Tag.ATOM_TAG }; // Atom 0 = []

    // =========================================================================
    // Type Tests
    // =========================================================================

    pub inline fn isSmallInt(self: Term) bool {
        return (self.value & Tag.TAG_MASK) == Tag.SMALL_INT_TAG;
    }

    pub inline fn isAtom(self: Term) bool {
        return (self.value & Tag.TAG_MASK) == Tag.ATOM_TAG;
    }

    pub inline fn isBoxed(self: Term) bool {
        return (self.value & 0b11) == Tag.BOXED_TAG;
    }

    pub inline fn isLiteral(self: Term) bool {
        return (self.value & Tag.TAG_MASK) == Tag.LITERAL_TAG;
    }

    pub inline fn isPID(self: Term) bool {
        return (self.value & Tag.TAG_MASK) == Tag.PID_TAG;
    }

    pub inline fn isPort(self: Term) bool {
        return (self.value & Tag.TAG_MASK) == Tag.PORT_TAG;
    }

    pub inline fn isRef(self: Term) bool {
        return (self.value & Tag.TAG_MASK) == Tag.REF_TAG;
    }

    pub inline fn isList(self: Term) bool {
        // Lists are boxed with header tag LIST
        if (!self.isBoxed()) return false;
        const header = self.getBoxedPtr(Header);
        return header.tag == .list;
    }

    pub inline fn isTuple(self: Term) bool {
        if (!self.isBoxed()) return false;
        const header = self.getBoxedPtr(Header);
        return header.tag == .tuple;
    }

    pub inline fn isNil(self: Term) bool {
        // NIL is atom 0
        return self.value == (@as(u64, 0) << 4) | Tag.ATOM_TAG;
    }

    // =========================================================================
    // Value Extraction
    // =========================================================================

    pub inline fn getSmallIntValue(self: Term) i64 {
        std.debug.assert(self.isSmallInt());
        // Arithmetic shift right 4 to preserve sign
        const as_i64: i64 = @bitCast(self.value);
        return as_i64 >> 4;
    }

    pub inline fn getAtomIndex(self: Term) u32 {
        std.debug.assert(self.isAtom());
        return @intCast(self.value >> 4);
    }

    pub inline fn getLiteralIndex(self: Term) u32 {
        std.debug.assert(self.isLiteral());
        return @intCast(self.value >> 4);
    }

    pub inline fn getBoxedPtr(self: Term, comptime T: type) *T {
        std.debug.assert(self.isBoxed());
        // Clear low 2 bits to get actual pointer
        const ptr_value = self.value & ~@as(u64, 0b11);
        return @ptrFromInt(ptr_value);
    }

    // =========================================================================
    // Boxed Header Access
    // =========================================================================

    pub inline fn getHeader(self: Term) *Header {
        std.debug.assert(self.isBoxed());
        return self.getBoxedPtr(Header);
    }
};

// ============================================================================
// Boxed Header Format
// ============================================================================

// BEAM boxed header layout (64-bit):
// [arity:26][tag:6][gc_mark:2] - simplified representation
pub const Header = packed struct(u64) {
    gc_mark: u2,
    tag: u6,
    arity: u26,
    padding: u30,

    pub inline fn init(tag: HeaderTag, arity: u32) Header {
        return .{
            .gc_mark = 0,
            .tag = @intFromEnum(tag),
            .arity = @intCast(arity),
            .padding = 0,
        };
    }

    pub inline fn getTag(self: *const Header) HeaderTag {
        return @as(HeaderTag, @enumFromInt(self.tag));
    }

    pub inline fn getArity(self: *const Header) u32 {
        return @intCast(self.arity);
    }
};

// ============================================================================
// Cons Cell (List)
// ============================================================================

pub const Cons = extern struct {
    header: Header,
    head: Term,
    tail: Term,

    pub inline fn init(head: Term, tail: Term) Cons {
        return .{
            .header = Header.init(.list, 2),
            .head = head,
            .tail = tail,
        };
    }
};

// ============================================================================
// Tuple
// ============================================================================

pub const Tuple = extern struct {
    header: Header,

    // Elements follow inline in memory
    pub fn getElements(self: *const Tuple) []const Term {
        const elements_ptr: [*]const Term = @ptrFromInt(@intFromPtr(self) + @sizeOf(Header));
        return elements_ptr[0..self.header.getArity()];
    }

    pub fn getElementsMut(self: *Tuple) []Term {
        const elements_ptr: [*]Term = @ptrFromInt(@intFromPtr(self) + @sizeOf(Header));
        return elements_ptr[0..self.header.getArity()];
    }
};

// ============================================================================
// Tests
// ============================================================================

test "small int roundtrip" {
    const t1 = Term.makeSmallInt(42);
    try std.testing.expect(t1.isSmallInt());
    try std.testing.expectEqual(@as(i64, 42), t1.getSmallIntValue());

    const t2 = Term.makeSmallInt(-1);
    try std.testing.expectEqual(@as(i64, -1), t2.getSmallIntValue());

    const t3 = Term.makeSmallInt(0);
    try std.testing.expectEqual(@as(i64, 0), t3.getSmallIntValue());
}

test "atom roundtrip" {
    const t1 = Term.makeAtom(0); // NIL
    try std.testing.expect(t1.isAtom());
    try std.testing.expectEqual(@as(u32, 0), t1.getAtomIndex());

    const t2 = Term.makeAtom(1);
    try std.testing.expect(t2.isAtom());
    try std.testing.expectEqual(@as(u32, 1), t2.getAtomIndex());

    const t3 = Term.makeAtom((1 << 19) - 1);
    try std.testing.expectEqual(@as(u32, (1 << 19) - 1), t3.getAtomIndex());
}

test "NIL is atom 0" {
    try std.testing.expect(Term.NIL.isAtom());
    try std.testing.expectEqual(@as(u32, 0), Term.NIL.getAtomIndex());
    try std.testing.expect(Term.NIL.isNil());
}

test "NIL is not boxed" {
    try std.testing.expect(!Term.NIL.isBoxed());
}

test "boxed pointer construction" {
    // Mock a heap allocation
    var buffer: [8]u8 align(8) = undefined;
    const ptr = @as(*u64, @ptrCast(&buffer));

    const term = Term.makeBoxed(&buffer);
    try std.testing.expect(term.isBoxed());

    const retrieved_ptr = term.getBoxedPtr(u64);
    try std.testing.expectEqual(@intFromPtr(ptr), @intFromPtr(retrieved_ptr));
}

test "tuple construction and access" {
    const allocator = std.testing.allocator;

    // Allocate space for tuple with 3 elements
    const tuple_size = @sizeOf(Tuple) + (3 * @sizeOf(Term));
    const memory = try allocator.alignedAlloc(u8, 8, tuple_size);
    defer allocator.free(memory);

    const tuple_ptr: *Tuple = @ptrCast(memory);
    tuple_ptr.header = Header.init(.tuple, 3);
    const elements = tuple_ptr.getElementsMut();

    elements[0] = Term.makeSmallInt(1);
    elements[1] = Term.makeSmallInt(2);
    elements[2] = Term.makeAtom(0);

    try std.testing.expectEqual(@as(u32, 3), tuple_ptr.header.getArity());
    try std.testing.expectEqual(@as(HeaderTag, .tuple), tuple_ptr.header.getTag());

    const read_elements = tuple_ptr.getElements();
    try std.testing.expectEqual(@as(i64, 1), read_elements[0].getSmallIntValue());
    try std.testing.expectEqual(@as(i64, 2), read_elements[1].getSmallIntValue());
    try std.testing.expectEqual(@as(u32, 0), read_elements[2].getAtomIndex());
}
