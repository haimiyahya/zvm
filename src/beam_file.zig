// src/beam_file.zig - BEAM file parser - FIXED version
// Fixes: chunk padding + zero-length atom misinterpretation
// Format: FOR1 <size> BEAM <chunks>
// Each chunk: ID (4 bytes) Size (4 bytes BE) Data (size bytes) Padding to 4 bytes

const std = @import("std");

pub const BeamError = error{
    InvalidHeader,
    InvalidChunk,
    Truncated,
    UnsupportedVersion,
    BadAtomTable,
};

pub const ChunkId = enum(u32) {
    Atom = 0x41746F6D, // "Atom"
    AtU8 = 0x41745538, // "AtU8"
    Code = 0x436F6465, // "Code"
    StrT = 0x53747254, // "StrT"
    ImpT = 0x496D7054, // "ImpT"
    ExpT = 0x45787054, // "ExpT"
    LitT = 0x4C697454, // "LitT"
    LocT = 0x4C6F6354,
    Attr = 0x41747472,
    CInf = 0x43496E66,
    Line = 0x4C696E65,
    Type = 0x54797065,
    FunT = 0x46756E54,
    _,

    pub fn fromBytes(b: [4]u8) ChunkId {
        const v = std.mem.readInt(u32, &b, .big);
        return @enumFromInt(v);
    }

    pub fn toString(self: ChunkId) []const u8 {
        return switch (self) {
            .Atom => "Atom",
            .AtU8 => "AtU8",
            .Code => "Code",
            .StrT => "StrT",
            .ImpT => "ImpT",
            .ExpT => "ExpT",
            .LitT => "LitT",
            .LocT => "LocT",
            .Attr => "Attr",
            .CInf => "CInf",
            .Line => "Line",
            .Type => "Type",
            .FunT => "FunT",
            _ => "Unknown",
        };
    }
};

pub const Chunk = struct {
    id: ChunkId,
    size: u32, // size from header, NOT padded
    data: []const u8,
};

pub const Import = struct {
    module: u32,
    function: u32,
    arity: u32,
};

pub const Export = struct {
    function: u32,
    arity: u32,
    label: u32,
};

pub const BeamFile = struct {
    allocator: std.mem.Allocator,
    raw: []const u8,
    chunks: std.ArrayList(Chunk),
    atoms: std.ArrayList([]const u8),
    imports: std.ArrayList(Import),
    exports: std.ArrayList(Export),
    code: []const u8,

    pub fn deinit(self: *BeamFile) void {
        for (self.atoms.items) |a| self.allocator.free(a);
        self.atoms.deinit();
        self.chunks.deinit();
        self.imports.deinit();
        self.exports.deinit();
        self.allocator.free(self.raw);
    }

    pub fn getAtom(self: *const BeamFile, index: u32) []const u8 {
        if (index == 0) return "[]";
        if (index - 1 < self.atoms.items.len) {
            return self.atoms.items[index - 1];
        }
        return "<bad atom>";
    }
};

pub fn parseBeamFile(allocator: std.mem.Allocator, path: []const u8) !BeamFile {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const raw = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    errdefer allocator.free(raw);
    return parseBeamBytes(allocator, raw);
}

pub fn parseBeamBytes(allocator: std.mem.Allocator, raw: []const u8) !BeamFile {
    if (raw.len < 12) return BeamError.Truncated;
    if (!std.mem.eql(u8, raw[0..4], "FOR1")) return BeamError.InvalidHeader;
    if (!std.mem.eql(u8, raw[8..12], "BEAM")) return BeamError.InvalidHeader;

    var offset: usize = 12;
    var chunks = std.ArrayList(Chunk).init(allocator);
    errdefer chunks.deinit();
    var atoms = std.ArrayList([]const u8).init(allocator);
    var imports = std.ArrayList(Import).init(allocator);
    var exports = std.ArrayList(Export).init(allocator);
    var code_data: []const u8 = &[_]u8{};

    while (offset + 8 <= raw.len) {
        const id_bytes: [4]u8 = raw[offset..][0..4].*;
        const id = ChunkId.fromBytes(id_bytes);
        const size = std.mem.readInt(u32, raw[offset + 4 ..][0..4], .big);
        const data_start = offset + 8;
        const data_end = data_start + size;

        if (data_end > raw.len) return BeamError.Truncated;

        // data is exactly size bytes, NOT including padding
        const data = raw[data_start..data_end];

        const chunk = Chunk{
            .id = id,
            .size = size,
            .data = data,
        };
        try chunks.append(chunk);

        switch (id) {
            .Atom => try parseAtomChunk(allocator, data, &atoms, .latin1),
            .AtU8 => try parseAtomChunk(allocator, data, &atoms, .utf8),
            .ImpT => try parseImpT(data, &imports),
            .ExpT => try parseExpT(data, &exports),
            .Code => code_data = data,
            else => {},
        }

        // CRITICAL FIX: next chunk position is based on header size + padding, not consumed bytes
        var next = data_end;
        const remainder = next % 4;
        if (remainder != 0) {
            next += 4 - remainder;
        }
        offset = next;
    }

    return BeamFile{
        .allocator = allocator,
        .raw = raw,
        .chunks = chunks,
        .atoms = atoms,
        .imports = imports,
        .exports = exports,
        .code = code_data,
    };
}

const AtomEncoding = enum { latin1, utf8 };

fn parseAtomChunk(allocator: std.mem.Allocator, data: []const u8, out: *std.ArrayList([]const u8), enc: AtomEncoding) !void {
    if (data.len < 4) return BeamError.BadAtomTable;
    const count = std.mem.readInt(u32, data[0..4], .big);
    var off: usize = 4;

    // Pre-allocate
    try out.ensureTotalCapacity(out.items.len + count);

    var parsed: u32 = 0;
    while (parsed < count) {
        if (off >= data.len) return BeamError.BadAtomTable;

        switch (enc) {
            .latin1 => {
                // CRITICAL FIX: Check if we're at the end before reading length
                if (off >= data.len) break;
                const len = data[off];
                off += 1;

                // If len == 0, this is padding, not a real atom
                if (len == 0) {
                    break; // Stop parsing, remaining bytes are padding
                }

                if (off + len > data.len) return BeamError.BadAtomTable;
                const str = try allocator.dupe(u8, data[off .. off + len]);
                try out.append(str);
                off += len;
                parsed += 1;
            },
            .utf8 => {
                // CRITICAL FIX: AtU8 uses 1-byte lengths, not 2-byte!
                // Check if we have enough bytes BEFORE reading length
                if (off >= data.len) break;
                const len = data[off];
                off += 1;

                // If len == 0, this is padding, not a real atom
                if (len == 0) {
                    break; // Stop parsing, remaining bytes are padding
                }

                if (off + len > data.len) return BeamError.BadAtomTable;
                const str = try allocator.dupe(u8, data[off .. off + len]);
                try out.append(str);
                off += len;
                parsed += 1;
            },
        }
    }

    // After parsing, off should be <= data.len, and may be == data.len
    // It should NOT exceed data.len
}

fn parseImpT(data: []const u8, out: *std.ArrayList(Import)) !void {
    if (data.len < 4) return BeamError.InvalidChunk;
    const count = std.mem.readInt(u32, data[0..4], .big);
    var off: usize = 4;
    for (0..count) |_| {
        if (off + 12 > data.len) return BeamError.InvalidChunk;
        const mod = std.mem.readInt(u32, data[off..][0..4], .big);
        const fun = std.mem.readInt(u32, data[off + 4 ..][0..4], .big);
        const arity = std.mem.readInt(u32, data[off + 8 ..][0..4], .big);
        try out.append(.{ .module = mod, .function = fun, .arity = arity });
        off += 12;
    }
}

fn parseExpT(data: []const u8, out: *std.ArrayList(Export)) !void {
    if (data.len < 4) return BeamError.InvalidChunk;
    const count = std.mem.readInt(u32, data[0..4], .big);
    var off: usize = 4;
    for (0..count) |_| {
        if (off + 12 > data.len) return BeamError.InvalidChunk;
        const fun = std.mem.readInt(u32, data[off..][0..4], .big);
        const arity = std.mem.readInt(u32, data[off + 4 ..][0..4], .big);
        const label = std.mem.readInt(u32, data[off + 8 ..][0..4], .big);
        try out.append(.{ .function = fun, .arity = arity, .label = label });
        off += 12;
    }
}

pub fn listBeamFiles(allocator: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(allocator);
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".beam")) {
            const full = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            try list.append(full);
        }
    }
    return list.toOwnedSlice();
}