// src/disasm.zig - BEAM disassembler for Phase 1 validation
// Exit criteria: Can disassemble all kernel, stdlib beams from OTP 26/27/28

const std = @import("std");
const beam_file = @import("beam_file.zig");

// Subset of BEAM opcodes - OTP 26 has ~160. We list most common for Phase 1.
// Source: lib/compiler/src/genop.tab and erts/emulator/beam/beam_opcodes.h
pub const Opcode = enum(u8) {
    label = 1,
    func_info = 2,
    int_code_end = 3,
    call = 4,
    call_last = 5,
    call_only = 6,
    call_ext = 7,
    call_ext_last = 8,
    bif0 = 9,
    bif1 = 10,
    bif2 = 11,
    allocate = 12,
    allocate_heap = 13,
    allocate_zero = 14,
    allocate_heap_zero = 15,
    test_heap = 16,
    init = 17,
    deallocate = 18,
    @"return" = 19,
    send = 20,
    remove_message = 21,
    timeout = 22,
    loop_rec = 23,
    loop_rec_end = 24,
    wait = 25,
    wait_timeout = 26,
    is_lt = 39,
    is_ge = 40,
    is_eq = 41,
    is_ne = 42,
    is_eq_exact = 43,
    is_ne_exact = 44,
    is_tuple = 45,
    is_atom = 46,
    // ... truncated for Phase 1 - we decode generically
    move = 64,
    get_tuple_element = 66,
    set_tuple_element = 67,
    is_nonempty_list = 69,
    jump = 70,
    catch_end = 78,
    select_val = 90,
    bs_start_match = 100,
    bs_get_integer = 101,
    bs_match = 102,

    pub fn name(self: Opcode) []const u8 {
        return @tagName(self);
    }
};

// BEAM uses compact term encoding for code
// See beam_book.org - Code chunk encoding
pub const CodeReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn eof(self: *CodeReader) bool {
        return self.pos >= self.data.len;
    }

    pub fn readByte(self: *CodeReader) !u8 {
        if (self.pos >= self.data.len) return error.Truncated;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    // BEAM small int encoding for code (different from term encoding)
    // Tag bits in low 3 bits
    pub fn readCodeInt(self: *CodeReader) !u64 {
        const b = try self.readByte();
        const tag = b & 0b111;
        if (tag == 0b000 or tag == 0b100) { // literal small < 16 encoded directly
            return b >> 4;
        }
        // Full encoding: need to implement full BEAM compact term decoder
        // For Phase 1, implement simple version
        if ((b & 0b111) == 0b111) {
            // extended
            const next = try self.readByte();
            if (next == 0) {
                // big
                const len = try self.readByte();
                var val: u64 = 0;
                for (0..len) |_| {
                    val = (val << 8) | try self.readByte();
                }
                return val;
            }
        }
        return b >> 3;
    }

    pub fn readOp(self: *CodeReader) !u8 {
        return self.readByte();
    }
};

pub fn disassembleFile(allocator: std.mem.Allocator, path: []const u8, writer: anytype) !void {
    var bf = try beam_file.parseBeamFile(allocator, path);
    defer bf.deinit();

    try writer.print("File: {s}\n", .{path});
    try writer.print("Atoms: {d}\n", .{bf.atoms.items.len});
    for (0..bf.atoms.items.len) |i| {
        const atom = bf.atoms.items[i];
        try writer.print("  {d}: {s}\n", .{ i + 1, atom });
    }

    // Print imports if available
    if (bf.imports.items.len > 0) {
        try writer.print("Imports: {d}\n", .{bf.imports.items.len});
        for (bf.imports.items) |imp| {
            try writer.print("  {s}:{s}/{d}\n", .{ bf.getAtom(imp.module), bf.getAtom(imp.function), imp.arity });
        }
    }

    // Print exports if available
    if (bf.exports.items.len > 0) {
        try writer.print("Exports: {d}\n", .{bf.exports.items.len});
        for (bf.exports.items) |exp| {
            try writer.print("  {s}/{d} label {d}\n", .{ bf.getAtom(exp.function), exp.arity, exp.label });
        }
    }

    // Print detected chunks for Phase 1 validation
    try writer.print("Detected chunks: {d}\n", .{bf.chunks.items.len});
    for (bf.chunks.items) |chunk| {
        try writer.print("  {s}: {d} bytes", .{ chunk.id.toString(), chunk.size });
        if (chunk.id == .LitT) {
            try writer.print(" [detected but not decoded in Phase 1]", .{});
        }
        try writer.print("\n", .{});
    }

    // Disassemble Code chunk if available
    if (bf.code.len > 0) {
        const code = bf.code;
        if (code.len < 20) {
            try writer.print("Code chunk too small\n", .{});
            return;
        }
        // According to BEAM Book: SubSize, InstructionSet, OpcodeMax, LabelCount, FunctionCount
        const sub_size = std.mem.readInt(u32, code[0..4], .big);
        const instruction_set = std.mem.readInt(u32, code[4..8], .big);
        const max_opcode = std.mem.readInt(u32, code[8..12], .big);
        const label_count = std.mem.readInt(u32, code[12..16], .big);
        const func_count = std.mem.readInt(u32, code[16..20], .big);
        try writer.print("Code header: sub_size {d} instruction_set {d} max_opcode {d} labels {d} funcs {d}\n", .{ sub_size, instruction_set, max_opcode, label_count, func_count });

        var reader = CodeReader{ .data = code[20..] };
        var instr_count: usize = 0;
        while (!reader.eof() and instr_count < 500) { // limit for Phase 1
            const op_byte = reader.readOp() catch break;
            // Try to convert to opcode enum, but skip undefined ones
            const op_result = std.meta.intToEnum(Opcode, op_byte);
            if (op_result) |op| {
                try writer.print("  {d:4}: {s} ({d})\n", .{ reader.pos - 1, @tagName(op), op_byte });
            } else |_| {
                try writer.print("  {d:4}: opcode_{d} ({d})\n", .{ reader.pos - 1, op_byte, op_byte });
            }
            instr_count += 1;
            if (op_byte == 3) break; // int_code_end
        }
        try writer.print("Disassembled {d} instructions\n", .{instr_count});
    } else {
        try writer.print("No code chunk found\n", .{});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <file.beam or directory>\n", .{args[0]});
        std.debug.print("Phase 1 exit criteria: disassemble kernel and stdlib\n", .{});
        return;
    }

    const target = args[1];
    if (std.fs.cwd().statFile(target)) |_| {
        // single file
        const out = std.io.getStdOut().writer();
        try disassembleFile(allocator, target, out);
    } else |err| {
        // try as directory
        std.debug.print("statFile failed: {any}, trying as directory\n", .{err});
        const files = try beam_file.listBeamFiles(allocator, target);
        defer {
            for (files) |f| allocator.free(f);
            allocator.free(files);
        }
        std.debug.print("Found {d} beam files in {s}\n", .{ files.len, target });
        for (files) |f| {
            const out = std.io.getStdOut().writer();
            disassembleFile(allocator, f, out) catch |e| {
                std.debug.print("FAIL {s}: {any}\n", .{ f, e });
                continue;
            };
        }
    }
}
