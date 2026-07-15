// src/bif.zig - Built-In Functions for Phase 2A
// Handles call_ext for arithmetic and type checks inline without trap
// For Phase 2A we do no trapping, no yielding, just direct compute

const std = @import("std");
const term = @import("term.zig");

pub const BifError = error{
    BadArg,
    BadArith,
    Unimplemented,
};

pub const BifResult = union(enum) {
    ok: term.Term,
    error_result: term.Term,
    unimplemented: void,
};

// Simple BIF dispatcher for erlang module
// xregs is slice of X registers, arity tells how many args
pub fn handleErlangBif(
    module: []const u8,
    function: []const u8,
    arity: u32,
    xregs: []term.Term,
) BifResult {

    if (!std.mem.eql(u8, module, "erlang")) {
        return .{ .unimplemented = {} };
    }

    // Arithmetic: +/2
    if (std.mem.eql(u8, function, "+") and arity == 2) {
        const a = xregs[0];
        const b = xregs[1];
        if (a.isSmallInt() and b.isSmallInt()) {
            const av = a.getSmallIntValue();
            const bv = b.getSmallIntValue();
            // Check overflow for 60-bit - for Phase 2A we ignore and just add
            // In real BEAM, overflow promotes to big int
            const res = av + bv;
            return .{ .ok = term.Term.makeSmallInt(res) };
        }
        return .{ .error_result = term.Term.makeAtom(0) }; // badarg
    }

    // Arithmetic: -/2
    if (std.mem.eql(u8, function, "-") and arity == 2) {
        const a = xregs[0];
        const b = xregs[1];
        if (a.isSmallInt() and b.isSmallInt()) {
            return .{ .ok = term.Term.makeSmallInt(a.getSmallIntValue() - b.getSmallIntValue()) };
        }
        return .{ .error_result = term.Term.makeAtom(0) };
    }

    // Arithmetic: */2
    if (std.mem.eql(u8, function, "*") and arity == 2) {
        const a = xregs[0];
        const b = xregs[1];
        if (a.isSmallInt() and b.isSmallInt()) {
            return .{ .ok = term.Term.makeSmallInt(a.getSmallIntValue() * b.getSmallIntValue()) };
        }
        return .{ .error_result = term.Term.makeAtom(0) };
    }

    // Arithmetic: div/2
    if (std.mem.eql(u8, function, "div") and arity == 2) {
        const a = xregs[0];
        const b = xregs[1];
        if (a.isSmallInt() and b.isSmallInt()) {
            const bv = b.getSmallIntValue();
            if (bv == 0) return .{ .error_result = term.Term.makeAtom(0) };
            return .{ .ok = term.Term.makeSmallInt(@divTrunc(a.getSmallIntValue(), bv)) };
        }
        return .{ .error_result = term.Term.makeAtom(0) };
    }

    // Arithmetic: rem/2
    if (std.mem.eql(u8, function, "rem") and arity == 2) {
        const a = xregs[0];
        const b = xregs[1];
        if (a.isSmallInt() and b.isSmallInt()) {
            const bv = b.getSmallIntValue();
            if (bv == 0) return .{ .error_result = term.Term.makeAtom(0) };
            return .{ .ok = term.Term.makeSmallInt(@rem(a.getSmallIntValue(), bv)) };
        }
        return .{ .error_result = term.Term.makeAtom(0) };
    }

    // Comparison BIFs used for guards - we implement as BIFs for simplicity in Phase 2A
    // In real BEAM these are instructions is_lt etc, but erlang:'=<'/2 also exists

    return .{ .unimplemented = {} };
}

// Helper to check if a bif is implemented
pub fn isImplemented(module: []const u8, function: []const u8, arity: u32) bool {
    if (!std.mem.eql(u8, module, "erlang")) return false;
    if (std.mem.eql(u8, function, "+") and arity == 2) return true;
    if (std.mem.eql(u8, function, "-") and arity == 2) return true;
    if (std.mem.eql(u8, function, "*") and arity == 2) return true;
    if (std.mem.eql(u8, function, "div") and arity == 2) return true;
    if (std.mem.eql(u8, function, "rem") and arity == 2) return true;
    return false;
}