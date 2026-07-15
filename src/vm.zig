// src/vm.zig - BEAM Virtual Machine Execution Context
// Target: OTP 26+ compatible VM for instruction execution

const std = @import("std");
const term = @import("term.zig");
const beam_file = @import("beam_file.zig");
const control_flow = @import("control_flow.zig");

// ============================================================================
// VM Configuration and Constants
// ============================================================================

pub const MAX_X_REGS = 1024; // Maximum X registers
pub const MAX_Y_REGS = 1024; // Maximum Y registers
pub const STACK_SIZE = 1024; // Stack size in terms
pub const HEAP_SIZE = 1024 * 1024; // Heap size in bytes (1MB)

// ============================================================================
// Execution Context - Process State
// ============================================================================

pub const Process = struct {
    // X registers - main registers for function arguments and returns
    x_regs: [MAX_X_REGS]term.Term,

    // Y registers - temporary registers for function calls
    y_regs: [MAX_Y_REGS]term.Term,

    // Stack - for returns and intermediate values
    stack: [STACK_SIZE]term.Term,
    stack_ptr: usize = 0,

    // Heap - for allocated terms (tuples, lists, etc.)
    heap: []u8,
    heap_ptr: usize = 0,
    heap_end: usize,

    // Instruction pointer
    ip: usize = 0,

    // Current function info
    current_function: ?FunctionInfo = null,

    // Allocator for memory management
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Process {
        const heap_memory = try allocator.alloc(u8, HEAP_SIZE);
        errdefer allocator.free(heap_memory);

        var proc = Process{
            .x_regs = undefined,
            .y_regs = undefined,
            .stack = undefined,
            .heap = heap_memory,
            .heap_ptr = 0,
            .heap_end = HEAP_SIZE,
            .allocator = allocator,
        };

        // Initialize registers to NIL
        for (0..MAX_X_REGS) |i| {
            proc.x_regs[i] = term.Term.NIL;
        }
        for (0..MAX_Y_REGS) |i| {
            proc.y_regs[i] = term.Term.NIL;
        }

        return proc;
    }

    pub fn deinit(self: *Process) void {
        self.allocator.free(self.heap);
    }

    // Stack operations
    pub fn stackPush(self: *Process, value: term.Term) !void {
        if (self.stack_ptr >= STACK_SIZE) return error.StackOverflow;
        self.stack[self.stack_ptr] = value;
        self.stack_ptr += 1;
    }

    pub fn stackPop(self: *Process) !term.Term {
        if (self.stack_ptr == 0) return error.StackUnderflow;
        self.stack_ptr -= 1;
        return self.stack[self.stack_ptr];
    }

    // Heap operations (simplified for Phase 2)
    pub fn heapAllocate(self: *Process, size: usize) ![]u8 {
        const aligned_size = ((size + 7) & ~@as(usize, 7)); // 8-byte align
        if (self.heap_ptr + aligned_size > self.heap_end) return error.OutOfMemory;
        const memory = self.heap[self.heap_ptr..];
        self.heap_ptr += aligned_size;
        return memory[0..size];
    }
};

// ============================================================================
// Function Information
// ============================================================================

pub const FunctionInfo = struct {
    name: []const u8,
    arity: u32,
    start_label: u32,
    module: []const u8,
};

// ============================================================================
// VM State
// ============================================================================

pub const VM = struct {
    process: Process,
    beam_file: beam_file.BeamFile,
    code_data: []const u8,
    cf: control_flow.ControlFlowState,

    pub fn init(allocator: std.mem.Allocator, bf: beam_file.BeamFile) !VM {
        const proc = try Process.init(allocator);
        errdefer proc.deinit();

        return VM{
            .process = proc,
            .beam_file = bf,
            .code_data = bf.code,
            .cf = control_flow.ControlFlowState.init(allocator),
        };
    }

    pub fn deinit(self: *VM) void {
        self.cf.deinit();
        self.process.deinit();
    }

    // Main execution loop - this is where we'll run BEAM instructions
    pub fn run(self: *VM) !void {
        std.debug.print("Starting BEAM VM execution...\n", .{});
        std.debug.print("Code size: {d} bytes\n", .{self.code_data.len});

        // For Phase 2, we'll implement basic instruction execution
        // Start with finding and executing a specific function
    }

    // Find function by name and arity
    pub fn findFunction(self: *const VM, name: []const u8, arity: u32) ?FunctionInfo {
        for (self.beam_file.exports.items) |exp| {
            const atom_name = self.beam_file.getAtom(exp.function);
            if (std.mem.eql(u8, atom_name, name) and exp.arity == arity) {
                return FunctionInfo{
                    .name = name,
                    .arity = arity,
                    .start_label = exp.label,
                    .module = "test", // TODO: get from atom table
                };
            }
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "process initialization" {
    const allocator = std.testing.allocator;
    var proc = try Process.init(allocator);
    defer proc.deinit();

    // Check registers are initialized to NIL
    try std.testing.expectEqual(term.Term.NIL, proc.x_regs[0]);
    try std.testing.expectEqual(term.Term.NIL, proc.y_regs[0]);

    // Check stack is empty
    try std.testing.expectEqual(@as(usize, 0), proc.stack_ptr);
}

test "stack push and pop" {
    const allocator = std.testing.allocator;
    var proc = try Process.init(allocator);
    defer proc.deinit();

    const value1 = term.Term.makeSmallInt(42);
    const value2 = term.Term.makeSmallInt(99);

    try proc.stackPush(value1);
    try proc.stackPush(value2);

    const popped2 = try proc.stackPop();
    const popped1 = try proc.stackPop();

    try std.testing.expectEqual(@as(i64, 99), popped2.getSmallIntValue());
    try std.testing.expectEqual(@as(i64, 42), popped1.getSmallIntValue());
}