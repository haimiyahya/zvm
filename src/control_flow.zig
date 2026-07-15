// src/control_flow.zig - Phase 2B control flow opcodes
// Implements: is_eq_exact, jump, call, call_last, label handling
// These enable fact/1: base case check, branching, recursion

const std = @import("std");
const term = @import("term.zig");

pub const ControlFlowError = error{
    BadLabel,
    StackUnderflow,
    BadTerm,
};

// Label table - maps label id -> code position (ip)
// BEAM labels are integers from 0 to label_count-1
// Built once after loading Code chunk
pub const LabelTable = struct {
    allocator: std.mem.Allocator,
    // label id -> code offset (ip)
    table: std.AutoHashMap(u32, usize),

    pub fn init(allocator: std.mem.Allocator) LabelTable {
        return LabelTable{
            .allocator = allocator,
            .table = std.AutoHashMap(u32, usize).init(allocator),
        };
    }

    pub fn deinit(self: *LabelTable) void {
        self.table.deinit();
    }

    pub fn add(self: *LabelTable, label_id: u32, ip: usize) !void {
        try self.table.put(label_id, ip);
    }

    pub fn get(self: *LabelTable, label_id: u32) !usize {
        if (self.table.get(label_id)) |ip| {
            return ip;
        }
        return ControlFlowError.BadLabel;
    }
};

// Exact equality for BEAM is_eq_exact
// In BEAM, is_eq_exact is strict: 1 == 1.0 is false, unlike ==
// For Phase 2B we only need small int exact equality
pub fn isEqExact(a: term.Term, b: term.Term) bool {
    // Fast path: raw bits equal
    if (a.value == b.value) return true;

    // If both small ints, compare values
    if (a.isSmallInt() and b.isSmallInt()) {
        return a.getSmallIntValue() == b.getSmallIntValue();
    }

    // If both atoms, compare index
    if (a.isAtom() and b.isAtom()) {
        return a.getAtomIndex() == b.getAtomIndex();
    }

    // For boxed types in Phase 2B, we only do raw equality
    // Later phases need to deref boxed header and compare content
    return false;
}

// VM extension for control flow - add these fields to your VM struct
pub const ControlFlowState = struct {
    // Current CP - where return goes (continuation pointer)
    cp: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ControlFlowState {
        _ = allocator;
        return ControlFlowState{
            .cp = 0,
        };
    }

    pub fn deinit(self: *ControlFlowState) void {
        _ = self;
        // No dynamic allocation in single stack model
    }
};