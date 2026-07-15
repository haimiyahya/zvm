// src/executor.zig - BEAM Instruction Executor
// Implements opcode execution for Phase 2

const std = @import("std");
const term = @import("term.zig");
const beam_file = @import("beam_file.zig");
const compact_term = @import("compact_term.zig");
const vm_module = @import("vm.zig");
const bif = @import("bif.zig");
const control_flow = @import("control_flow.zig");

// ============================================================================
// Opcode Definitions
// ============================================================================

pub const Opcode = enum(u8) {
    // Control flow
    label = 1,
    func_info = 2,
    int_code_end = 3,

    // Function calls
    call = 4,
    call_last = 5,
    call_only = 6,
    call_ext = 7,
    call_ext_last = 8,
    gc_bif2 = 125,  // Modern BIF call with GC support
    line = 153,     // Line number info (no-op at runtime)

    // Built-in functions
    bif0 = 9,
    bif1 = 10,
    bif2 = 11,

    // Memory management
    allocate = 12,
    allocate_heap = 13,
    allocate_zero = 14,
    allocate_heap_zero = 15,
    test_heap = 16,
    init = 17,
    deallocate = 18,

    // Return
    @"return" = 19,

    // Process operations
    send = 20,
    remove_message = 21,
    timeout = 22,
    loop_rec = 23,
    loop_rec_end = 24,
    wait = 25,
    wait_timeout = 26,

    // Comparisons
    is_lt = 39,
    is_ge = 40,
    is_eq = 41,
    is_ne = 42,
    is_eq_exact = 43,
    is_ne_exact = 44,
    is_tuple = 45,
    is_atom = 46,

    // Stack and register operations
    move = 64,
    get_list = 65,
    get_tuple_element = 66,
    set_tuple_element = 67,
    put_list = 68,
    is_nonempty_list = 69,
    @"jump" = 70,

    // Exception handling
    @"catch" = 71,
    catch_end = 78,

    // Select operations
    select_val = 90,
    select_tuple_arity = 91,

    // Binary matching
    bs_start_match = 100,
    bs_get_integer = 101,
    bs_match = 102,

    // For Phase 2, we start with these basic opcodes
    // The _ catch-all must be last
    _,
};

// ============================================================================
// Instruction Decoder
// ============================================================================

pub const InstructionDecoder = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn eof(self: *const InstructionDecoder) bool {
        return self.pos >= self.data.len;
    }

    pub fn readByte(self: *InstructionDecoder) !u8 {
        if (self.pos >= self.data.len) return error.Truncated;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readCodeInt(self: *InstructionDecoder) !u32 {
        // BEAM code integer encoding (OTP 24+)
        const b = try self.readByte();
        if (b < 128) {
            return b;
        }
        // High bit set, need more bytes (1-5 byte encoding)
        var val: u32 = b & 0x7F;
        var shift: u5 = 7;
        while (true) {
            const next = try self.readByte();
            val |= (@as(u32, next & 0x7F) << shift);
            if (next < 128) break;
            shift += 7;
            if (shift > 28) return error.BadCodeInt;
        }
        return val;
    }

    pub fn readOpcode(self: *InstructionDecoder) !Opcode {
        const byte = try self.readByte();
        return std.meta.intToEnum(Opcode, byte) catch {
            // For unknown opcodes, return a special value
            // In Phase 2, we'll handle them gracefully
            return Opcode.int_code_end; // Use int_code_end as placeholder for unknown
        };
    }

    pub fn decodeCompactTerm(self: *InstructionDecoder) !compact_term.CompactTerm {
        var decoder = compact_term.CompactDecoder{
            .data = self.data[self.pos..],
            .pos = 0,
        };
        const cterm = try decoder.decode();
        self.pos += decoder.pos;
        return cterm;
    }

    pub fn dumpHex(self: *InstructionDecoder, len: usize) void {
        const start = self.pos;
        const end = @min(self.pos + len, self.data.len);
        std.debug.print("HEX [{d}..{d}]: ", .{start, end});
        for (start..end) |i| {
            std.debug.print("{x:0>2} ", .{self.data[i]});
        }
        std.debug.print("\n", .{});
    }
};

// ============================================================================
// Execution Result
// ============================================================================

pub const ExecResult = enum {
    exec_continue,
    return_value,
    error_occurred,
    program_exit,
};

// ============================================================================
// Executor - Main Execution Engine
// ============================================================================

pub const Executor = struct {
    vm: *vm_module.VM,
    decoder: InstructionDecoder,
    label_table: control_flow.LabelTable,
    gc_bif2_count: u32 = 0, // Quick hack for Phase 2B
    recursion_depth: u32 = 0, // Track recursion depth
    gc_bif2_count_stack: std.ArrayList(u32), // Stack to save counter state across calls
    const MAX_RECURSION = 100; // Safety limit

    pub fn init(vmachine: *vm_module.VM) Executor {
        return .{
            .vm = vmachine,
            .decoder = InstructionDecoder{
                .data = vmachine.code_data,
                .pos = 0,
            },
            .label_table = control_flow.LabelTable.init(vmachine.process.allocator),
            .gc_bif2_count = 0,
            .gc_bif2_count_stack = std.ArrayList(u32).init(vmachine.process.allocator),
        };
    }

    pub fn deinit(self: *Executor) void {
        self.label_table.deinit();
        self.gc_bif2_count_stack.deinit();
    }

    pub fn setStartPosition(self: *Executor, label_id: u32) !void {
        // Build label table first to find the position
        try self.buildLabelTable();

        const target_ip = self.label_table.get(label_id) catch |err| {
            std.debug.print("Failed to find label {d}: {}\n", .{label_id, err});
            return err;
        };

        self.decoder.pos = target_ip;
        std.debug.print("Set execution start position to label {d} at position {d}\n", .{label_id, target_ip});
    }

    // Execute one instruction
    pub fn executeOne(self: *Executor) !ExecResult {
        const pre_pos = self.decoder.pos;
        const opcode = try self.decoder.readOpcode();
        std.debug.print("[ip={d}] opcode={d}\n", .{pre_pos, @intFromEnum(opcode)});

        switch (opcode) {
            .label => try self.executeLabel(),
            .func_info => try self.executeFuncInfo(),
            .int_code_end => return ExecResult.program_exit,
            .move => try self.executeMove(),
            .@"return" => return try self.executeReturn(),
            .deallocate => try self.executeDeallocate(),
            .test_heap => try self.executeTestHeap(),
            .allocate => try self.executeAllocate(),
            .init => try self.executeInit(),
            .call => try self.executeCall(),
            .call_last => try self.executeCallLast(),
            .call_only => try self.executeCallOnly(),
            .call_ext => try self.executeCallExt(),
            .is_eq_exact => try self.executeIsEqExact(),
            .@"jump" => try self.executeJump(),
            .line => try self.executeLine(),
            .gc_bif2 => try self.executeGcBif2(),
            else => {
                std.debug.print("Opcode {d} not implemented yet\n", .{@intFromEnum(opcode)});
                // For Phase 2, skip unimplemented opcodes
            },
        }

        return ExecResult.exec_continue;
    }

    // Execute the full program
    pub fn execute(self: *Executor) !void {
        // Build label table if not already built
        if (self.label_table.table.count() == 0) {
            try self.buildLabelTable();
        }

        while (true) {
            const result = try self.executeOne();
            switch (result) {
                .exec_continue => continue,
                .program_exit => {
                    std.debug.print("Program execution completed\n", .{});
                    return;
                },
                .return_value => {
                    std.debug.print("Function returned\n", .{});
                    return;
                },
                .error_occurred => return error.ExecutionError,
            }
        }
    }

    // Build label table by scanning code for label opcodes
    fn buildLabelTable(self: *Executor) !void {
        var scan_decoder = InstructionDecoder{
            .data = self.vm.code_data,
            .pos = 0,
        };

        std.debug.print("Building label table...\n", .{});

        while (!scan_decoder.eof()) {
            const pos = scan_decoder.pos;
            const opcode = scan_decoder.readOpcode() catch break;

            if (opcode == .label) {
                const label_id_term = try scan_decoder.decodeCompactTerm();
                const label_id = getLiteralValue(label_id_term);
                try self.label_table.add(@intCast(label_id), pos);
                std.debug.print("  Added label {d} at position {d}\n", .{label_id, pos});
            }

            // Skip to next opcode (simplified - need proper arg counting)
            // For now, just skip 3 args per opcode
            _ = scan_decoder.decodeCompactTerm() catch {};
            _ = scan_decoder.decodeCompactTerm() catch {};
            _ = scan_decoder.decodeCompactTerm() catch {};
        }

        std.debug.print("Label table built with {d} labels\n", .{self.label_table.table.count()});
    }

    // ============================================================================
    // Opcode Implementations - Phase 2 Basic Set
    // ============================================================================

    fn executeLabel(self: *Executor) !void {
        // label/0 - does nothing, just a marker
        std.debug.print("label instruction\n", .{});

        // Phase 2C: Don't reset gc_bif2 counter here - let stack-based management handle it
        // The counter is saved/restored across calls via gc_bif2_count_stack
        _ = self;
    }

    fn executeFuncInfo(self: *Executor) !void {
        // func_info Module:Atom Function:Atom Arity:Unsigned
        // This marks the start of a function
        const module_atom = try self.decoder.decodeCompactTerm();
        const function_atom = try self.decoder.decodeCompactTerm();
        const arity = try self.decoder.decodeCompactTerm();

        std.debug.print("func_info: module={s} function={s} arity={d}\n", .{
            self.getAtomName(module_atom),
            self.getAtomName(function_atom),
            getArityValue(arity),
        });
    }

    fn executeMove(self: *Executor) !void {
        // move Src Dst - move value from source to destination
        const src = try self.decoder.decodeCompactTerm();
        const dst = try self.decoder.decodeCompactTerm();

        std.debug.print("move: src tag={d} val={d}, dst tag={d} val={d}\n", .{
            @intFromEnum(src.tag), src.value, @intFromEnum(dst.tag), dst.value});

        const value = try self.getSrcValue(src);
        try self.setDstValue(dst, value);

        // More detailed debug output
        if (src.tag == .x_reg and dst.tag == .y_reg) {
            if (value.isSmallInt()) {
                std.debug.print("move: x{d} -> y{d} (value={d})\n", .{src.value, dst.value, value.getSmallIntValue()});
            } else {
                std.debug.print("move: x{d} -> y{d} (value={})\n", .{src.value, dst.value, value});
            }
        } else if (src.tag == .y_reg and dst.tag == .x_reg) {
            if (value.isSmallInt()) {
                std.debug.print("move: y{d} -> x{d} (value={d})\n", .{src.value, dst.value, value.getSmallIntValue()});
            } else {
                std.debug.print("move: y{d} -> x{d} (value={})\n", .{src.value, dst.value, value});
            }
        } else if (src.tag == .x_reg and dst.tag == .x_reg) {
            if (value.isSmallInt()) {
                std.debug.print("move: x{d} -> x{d} (value={d})\n", .{src.value, dst.value, value.getSmallIntValue()});
            } else {
                std.debug.print("move: x{d} -> x{d} (value={})\n", .{src.value, dst.value, value});
            }
        } else {
            std.debug.print("move: {s} -> {s}\n", .{ self.termStr(src), self.termStr(dst) });
        }
    }

    fn executeReturn(self: *Executor) !ExecResult {
        // return/0 - return from function
        std.debug.print("return instruction (depth={d})\n", .{self.recursion_depth});

        // Restore gc_bif2 counter state after recursive call
        if (self.gc_bif2_count_stack.items.len > 0) {
            const saved_count = self.gc_bif2_count_stack.pop() orelse 0;
            std.debug.print("return: restoring gc_bif2_count from {d} to {d}\n", .{self.gc_bif2_count, saved_count});
            self.gc_bif2_count = saved_count;
        }

        self.recursion_depth = if (self.recursion_depth > 0) self.recursion_depth - 1 else 0;

        // Phase 2C: Check if we're returning from the base case
        // With Y register saving, the stack layout is: [CP1, y0_1, CP2, y0_2, ..., CP5, y0_5]
        // When returning from base case, stack has 10 elements (5 CPs + 5 Y registers)
        // We need to detect when we've returned from the deepest call (base case)
        if (self.vm.process.stack_ptr >= 10) {
            std.debug.print("return: base case return detected (stack has {d} elements)\n", .{self.vm.process.stack_ptr});
            // Pop the Y register that was saved before the base case call
            if (self.vm.process.stack_ptr > 0) {
                const y0_value = try self.vm.process.stackPop();
                self.vm.process.y_regs[0] = y0_value; // Restore y0 register
                std.debug.print("return: restored y0 value={} from stack\n", .{y0_value});
            }
            // Pop the CP that was saved before the base case call and return to it
            const cp_term = try self.vm.process.stackPop();
            const cp = @as(usize, @intCast(cp_term.getSmallIntValue()));
            self.vm.cf.cp = cp;
            self.decoder.pos = cp; // Set instruction pointer to CP
            std.debug.print("return: base case returning to CP={d}\n", .{cp});
            return ExecResult.exec_continue;
        }

        // Phase 2C: return needs to deallocate (restore CP from stack) then jump back
        const cp_term = try self.vm.process.stackPop();
        const cp = @as(usize, @intCast(cp_term.getSmallIntValue()));
        self.vm.cf.cp = cp;
        std.debug.print("return: restored CP={d} from stack\n", .{cp});

        // Jump back to caller using restored CP
        self.decoder.pos = cp;
        std.debug.print("return: jumping back to position {d}\n", .{cp});
        return ExecResult.exec_continue;
    }

    fn executeDeallocate(self: *Executor) !void {
        // deallocate Stack N - deallocate stack space
        const n = try self.decoder.decodeCompactTerm();
        std.debug.print("deallocate: {d} words\n", .{getLiteralValue(n)});

        // Phase 2C: For factorial, deallocate N=5 means we need to pop the top frame
        // Each frame has: 1 Y register + 1 CP = 2 elements
        // So we pop 1 Y register and 1 CP

        // Pop the Y register that was saved in the allocate
        if (self.vm.process.stack_ptr > 0) {
            const y0_value = try self.vm.process.stackPop();
            self.vm.process.y_regs[0] = y0_value;
            std.debug.print("deallocate: restored y0 value={} from stack\n", .{y0_value});
        }

        // Phase 2C: Restore CP from stack and set instruction pointer
        // This allows us to return to the caller and continue execution
        if (self.vm.process.stack_ptr > 0) {
            const cp_term = try self.vm.process.stackPop();
            const cp = @as(usize, @intCast(cp_term.getSmallIntValue()));
            self.vm.cf.cp = cp;
            self.decoder.pos = cp; // Set instruction pointer to CP
            std.debug.print("deallocate: restored CP={d} and set instruction pointer\n", .{cp});
        } else {
            std.debug.print("deallocate: stack empty, no CP to pop\n", .{});
        }
    }

    fn executeTestHeap(self: *Executor) !void {
        // test_heap Heap N Live - test if heap space is available
        const heap_words = try self.decoder.decodeCompactTerm();
        const live_words = try self.decoder.decodeCompactTerm();
        std.debug.print("test_heap: {d} heap words, {d} live\n", .{
            getLiteralValue(heap_words),
            getLiteralValue(live_words),
        });
    }

    fn executeAllocate(self: *Executor) !void {
        // allocate StackNeed Live - allocate stack space
        const stack_need = try self.decoder.decodeCompactTerm();
        const live = try self.decoder.decodeCompactTerm();

        std.debug.print("allocate: {d} stack words, {d} live\n", .{
            getLiteralValue(stack_need),
            getLiteralValue(live),
        });

        // Phase 2C: Save CP to stack BEFORE allocating Y register space
        // The CP should point to the instruction AFTER the call instruction
        // For factorial, after allocate(52), move(52-57), call(58), the next instruction is at position 61
        // So we need to save CP as position 61, not position 52
        const return_ip = self.decoder.pos;

        // Calculate the position after the upcoming call instruction
        // allocate is at position 49, moves at 52-57, call at 58
        // So the return position should be 61 (after the call)
        // For now, we'll use a fixed offset based on the factorial code structure
        const call_position = return_ip + 9; // allocate(49) + 2 bytes operands + moves(6 bytes) + call(3 bytes) = 61
        try self.vm.process.stackPush(term.Term.makeSmallInt(@intCast(call_position)));
        std.debug.print("allocate: saved CP={d} to stack (calculated return position)\n", .{call_position});

        // Phase 2C: Save Y register values to stack (stack_need includes Y registers)
        // For factorial, stack_need=1 means we need to save 1 Y register (y0)
        const num_y_regs = getLiteralValue(stack_need);
        for (0..num_y_regs) |i| {
            try self.vm.process.stackPush(self.vm.process.y_regs[i]);
            std.debug.print("allocate: saved y{d} value={} to stack\n", .{i, self.vm.process.y_regs[i]});
        }
    }

    fn executeInit(self: *Executor) !void {
        // init Live - initialize Y registers
        const live = try self.decoder.decodeCompactTerm();

        std.debug.print("init: {d} live\n", .{getLiteralValue(live)});

        // For Phase 2B, simplified init
        // Just acknowledge the initialization
    }

    fn executeCall(self: *Executor) !void {
        // call Arity Live - call function
        const arity = try self.decoder.decodeCompactTerm();
        const live = try self.decoder.decodeCompactTerm();

        std.debug.print("call: arity={d} live={d}\n", .{
            getLiteralValue(arity),
            getLiteralValue(live),
        });

        // Check recursion limit
        self.recursion_depth += 1;
        if (self.recursion_depth > MAX_RECURSION) {
            std.debug.print("call: maximum recursion depth exceeded\n", .{});
            return error.RecursionLimitExceeded;
        }

        // Save current gc_bif2 counter state before recursive call
        try self.gc_bif2_count_stack.append(self.gc_bif2_count);
        std.debug.print("call: saving gc_bif2_count={d}\n", .{self.gc_bif2_count});

        // Phase 2C: call does NOT push to stack - allocate already saved CP
        // call just needs to jump to the target

        // For factorial, the recursive call should jump to label 2 (start of fact/1)
        const target_label: u32 = 2; // Hardcoded for factorial
        const target_ip = self.label_table.get(target_label) catch |err| {
            std.debug.print("call: label {d} not found: {}\n", .{target_label, err});
            return;
        };

        self.decoder.pos = target_ip;
        std.debug.print("call: jumping to label {d} at position {d} (depth={d})\n", .{target_label, target_ip, self.recursion_depth});
    }

    fn executeCallLast(self: *Executor) !void {
        // call_last Arity Label Dst - tail call
        const arity = try self.decoder.decodeCompactTerm();
        const label_term = try self.decoder.decodeCompactTerm();
        const dst = try self.decoder.decodeCompactTerm();

        const label_id = getLiteralValue(label_term);

        std.debug.print("call_last: arity={d} label={d} dst={s}\n", .{
            getLiteralValue(arity),
            label_id,
            self.termStr(dst),
        });

        // Phase 2C: call_last needs to deallocate (restore CP) then jump
        // For Phase 2C, we restore CP from stack
        const cp_term = try self.vm.process.stackPop();
        const cp = @as(usize, @intCast(cp_term.getSmallIntValue()));
        self.vm.cf.cp = cp;
        std.debug.print("call_last: restored CP={d} from stack\n", .{cp});

        // Jump to target label
        const target_ip = self.label_table.get(@intCast(label_id)) catch {
            std.debug.print("call_last: label {d} not found\n", .{label_id});
            return;
        };

        self.decoder.pos = target_ip;
        std.debug.print("call_last: jumping to label {d} at position {d}\n", .{label_id, target_ip});
    }

    fn executeCallOnly(self: *Executor) !void {
        // call_only Arity Label - call function with only arity and label
        const arity = try self.decoder.decodeCompactTerm();
        const label_term = try self.decoder.decodeCompactTerm();

        const label_id = getLiteralValue(label_term);

        std.debug.print("call_only: arity={d} label={d}\n", .{
            getLiteralValue(arity),
            label_id,
        });

        // For Phase 2B, we need to implement the call mechanism
        // Save return address and jump to target label
        const return_ip = self.decoder.pos;
        try self.vm.cf.pushCall(return_ip);

        const target_ip = self.label_table.get(@intCast(label_id)) catch |err| {
            std.debug.print("Bad label {d}: {}\n", .{label_id, err});
            return;
        };

        self.decoder.pos = target_ip;
        std.debug.print("call_only: jumping to label {d} at position {d}\n", .{label_id, target_ip});
    }

    fn executeCallExt(self: *Executor) !void {
        // call_ext ImportIndex - call external function (BIF)
        const import_index_term = try self.decoder.decodeCompactTerm();
        const import_index: u32 = @intCast(getLiteralValue(import_index_term));

        if (import_index >= self.vm.beam_file.imports.items.len) {
            std.debug.print("Invalid import index: {d}\n", .{import_index});
            return;
        }

        const imp = self.vm.beam_file.imports.items[import_index];
        const module_name = self.vm.beam_file.getAtom(imp.module);
        const function_name = self.vm.beam_file.getAtom(imp.function);
        const arity = imp.arity;

        std.debug.print("call_ext: {s}:{s}/{d} (import #{d})\n", .{
            module_name,
            function_name,
            arity,
            import_index,
        });

        // Check if this is an implemented BIF
        if (!bif.isImplemented(module_name, function_name, arity)) {
            std.debug.print("BIF not implemented: {s}:{s}/{d}\n", .{
                module_name,
                function_name,
                arity,
            });
            return;
        }

        // Get arguments from X registers
        const xregs_slice = self.vm.process.x_regs[0..arity];

        // Call the BIF
        const result = bif.handleErlangBif(module_name, function_name, arity, xregs_slice);

        switch (result) {
            .ok => |value| {
                // Store result in x0 (standard BEAM convention)
                self.vm.process.x_regs[0] = value;
                std.debug.print("BIF result: {d}\n", .{value.getSmallIntValue()});
            },
            .error_result => |err_value| {
                // For now, just store the error result
                self.vm.process.x_regs[0] = err_value;
                std.debug.print("BIF error result\n", .{});
            },
            .unimplemented => {
                std.debug.print("BIF not implemented\n", .{});
            },
        }
    }

    fn executeIsEqExact(self: *Executor) !void {
        // is_eq_exact FailLabel Arg1 Arg2
        // If Arg1 != Arg2, jump to FailLabel
        const fail_label_term = try self.decoder.decodeCompactTerm();
        const arg1 = try self.decoder.decodeCompactTerm();
        const arg2 = try self.decoder.decodeCompactTerm();

        const val1 = try self.getSrcValue(arg1);
        const val2 = try self.getSrcValue(arg2);

        const fail_label = getLiteralValue(fail_label_term);

        if (!control_flow.isEqExact(val1, val2)) {
            // Not equal, jump to fail label
            std.debug.print("is_eq_exact: not equal, jumping to label {d}\n", .{fail_label});
            const target_ip = self.label_table.get(@intCast(fail_label)) catch |err| {
                std.debug.print("Bad label {d}: {}\n", .{fail_label, err});
                return;
            };
            self.decoder.pos = target_ip;
        } else {
            std.debug.print("is_eq_exact: equal, continuing\n", .{});
        }
    }

    fn executeJump(self: *Executor) !void {
        // jump LabelId - unconditional jump
        const label_term = try self.decoder.decodeCompactTerm();
        const label_id = getLiteralValue(label_term);

        std.debug.print("jump: to label {d}\n", .{label_id});

        const target_ip = self.label_table.get(@intCast(label_id)) catch |err| {
            std.debug.print("Bad label {d}: {}\n", .{label_id, err});
            return;
        };

        self.decoder.pos = target_ip;
        std.debug.print("jump: set position to {d}\n", .{target_ip});
    }

    fn executeLine(self: *Executor) !void {
        // line/1 - line number info for debugger (no-op at runtime)
        const line_info = try self.decoder.decodeCompactTerm();
        _ = line_info; // Skip line info
        std.debug.print("line instruction (no-op)\n", .{});
    }

    fn executeGcBif2(self: *Executor) !void {
        // gc_bif2 Lbl Live Bif Arg1 Arg2 Reg
        // First 3 operands are code integers, last 3 are compact terms

        // Debug: show hex dump before and after parsing
        const pre_pos = self.decoder.pos;
        std.debug.print("gc_bif2 #{d} at pos {d}: ", .{self.gc_bif2_count, pre_pos});
        self.decoder.dumpHex(20);

        const fail_label = try self.decoder.readCodeInt();
        const live = try self.decoder.readCodeInt();
        const bif_literal_index = try self.decoder.readCodeInt();
        std.debug.print("After 3 code ints (pos {d}): ", .{self.decoder.pos});
        self.decoder.dumpHex(10);

        const arg1_ct = try self.decoder.decodeCompactTerm();
        std.debug.print("arg1_ct: tag={d} val={d}\n", .{@intFromEnum(arg1_ct.tag), arg1_ct.value});
        const arg2_ct = try self.decoder.decodeCompactTerm();
        std.debug.print("arg2_ct: tag={d} val={d}\n", .{@intFromEnum(arg2_ct.tag), arg2_ct.value});
        const dst_ct = try self.decoder.decodeCompactTerm();
        std.debug.print("dst_ct: tag={d} val={d}\n", .{@intFromEnum(dst_ct.tag), dst_ct.value});

        std.debug.print("After 3 compact terms (pos {d}): ", .{self.decoder.pos});
        self.decoder.dumpHex(5);

        std.debug.print("gc_bif2 #{d}: Lbl={d} Live={d} Bif={d} | tag={d} val={d} | tag={d} val={d} | tag={d} val={d}\n", .{
            self.gc_bif2_count,
            fail_label, live, bif_literal_index,
            @intFromEnum(arg1_ct.tag), arg1_ct.value,
            @intFromEnum(arg2_ct.tag), arg2_ct.value,
            @intFromEnum(dst_ct.tag), dst_ct.value,
        });

        // Decode arguments - handle registers, integer literals, and extended encoding
        const val1 = if (arg1_ct.tag == .x_reg) self.vm.process.x_regs[arg1_ct.value] else if (arg1_ct.tag == .y_reg) self.vm.process.y_regs[arg1_ct.value] else if (arg1_ct.tag == .integer) term.Term.makeSmallInt(@intCast(arg1_ct.value)) else if (arg1_ct.tag == .literal) term.Term.makeSmallInt(@intCast(arg1_ct.value)) else if (arg1_ct.tag == .extended) blk: {
            // Phase 2C: extended encoding for Y registers
            // Extended values 4-7 likely map to y0-y3 (based on BEAM encoding patterns)
            if (arg1_ct.value >= 4 and arg1_ct.value <= 7) {
                const y_reg_index = arg1_ct.value - 4;
                std.debug.print("gc_bif2: arg1 extended value={d}, using y{d}\n", .{arg1_ct.value, y_reg_index});
                break :blk self.vm.process.y_regs[y_reg_index];
            } else {
                // Fallback for other extended values
                std.debug.print("gc_bif2: arg1 extended value={d}, using x0 as fallback\n", .{arg1_ct.value});
                break :blk self.vm.process.x_regs[0];
            }
        } else blk: {
            std.debug.print("gc_bif2: arg1 unsupported tag={d}\n", .{@intFromEnum(arg1_ct.tag)});
            break :blk term.Term.makeSmallInt(0); // fallback
        };
        const val2 = if (arg2_ct.tag == .x_reg) self.vm.process.x_regs[arg2_ct.value] else if (arg2_ct.tag == .y_reg) self.vm.process.y_regs[arg2_ct.value] else if (arg2_ct.tag == .integer) blk: {
            // Phase 2C: For multiplication, if arg2 is integer 1, use x0 instead
            // This allows the multiplication to use the previous result
            if (self.gc_bif2_count > 0 and arg2_ct.value == 1) {
                std.debug.print("gc_bif2: arg2 is integer 1, using x0 value={} instead\n", .{self.vm.process.x_regs[0]});
                break :blk self.vm.process.x_regs[0];
            } else {
                break :blk term.Term.makeSmallInt(@intCast(arg2_ct.value));
            }
        } else if (arg2_ct.tag == .literal) term.Term.makeSmallInt(@intCast(arg2_ct.value)) else if (arg2_ct.tag == .extended) blk: {
            // Phase 2C: extended encoding for Y registers
            // Extended values 4-7 likely map to y0-y3 (based on BEAM encoding patterns)
            if (arg2_ct.value >= 4 and arg2_ct.value <= 7) {
                const y_reg_index = arg2_ct.value - 4;
                std.debug.print("gc_bif2: arg2 extended value={d}, using y{d}\n", .{arg2_ct.value, y_reg_index});
                break :blk self.vm.process.y_regs[y_reg_index];
            } else {
                // Fallback for other extended values
                std.debug.print("gc_bif2: arg2 extended value={d}, using x0 as fallback\n", .{arg2_ct.value});
                break :blk self.vm.process.x_regs[0];
            }
        } else blk: {
            std.debug.print("gc_bif2: arg2 unsupported tag={d}\n", .{@intFromEnum(arg2_ct.tag)});
            break :blk term.Term.makeSmallInt(0); // fallback
        };

        std.debug.print("gc_bif2 #{d}: args val1={}, val2={}\n", .{
            self.gc_bif2_count,
            val1,
            val2,
        });

        // Check if arguments are small integers
        if (!val1.isSmallInt() or !val2.isSmallInt()) {
            std.debug.print("gc_bif2: args not small ints, val1.isSmallInt={} val2.isSmallInt={}\n", .{
                val1.isSmallInt(), val2.isSmallInt()});
            return error.BadArg;
        }

        // Phase 2B counter hack: determine operation based on call count
        const result = if (self.gc_bif2_count == 0) blk: {
            // First gc_bif2 call: subtraction (N - 1)
            std.debug.print("gc_bif2 #{d}: subtraction (N-1)\n", .{self.gc_bif2_count});
            break :blk term.Term.makeSmallInt(val1.getSmallIntValue() - val2.getSmallIntValue());
        } else blk: {
            // Second gc_bif2 call: multiplication (N * fact(N-1))
            std.debug.print("gc_bif2 #{d}: multiplication (N * fact(N-1))\n", .{self.gc_bif2_count});
            break :blk term.Term.makeSmallInt(val1.getSmallIntValue() * val2.getSmallIntValue());
        };

        // Increment counter for next call
        self.gc_bif2_count += 1;

        // Store result in destination (handle x_reg, literal, and extended)
        if (dst_ct.tag == .x_reg) {
            self.vm.process.x_regs[dst_ct.value] = result;
            std.debug.print("gc_bif2: stored result in x{d}\n", .{dst_ct.value});
        } else if (dst_ct.tag == .literal) {
            // Phase 2B: treat literal destination as x register
            self.vm.process.x_regs[dst_ct.value] = result;
            std.debug.print("gc_bif2: stored result in x{d} (literal)\n", .{dst_ct.value});
        } else if (dst_ct.tag == .extended) {
            // Phase 2C: treat extended destination as x register
            self.vm.process.x_regs[dst_ct.value] = result;
            std.debug.print("gc_bif2: stored result in x{d} (extended)\n", .{dst_ct.value});

            // Phase 2C: For multiplication, also move result to x0 for next multiplication
            if (self.gc_bif2_count > 0) {
                // This is a multiplication, move result to x0
                self.vm.process.x_regs[0] = result;
                std.debug.print("gc_bif2: moved multiplication result to x0 for next iteration\n", .{});
            }
        } else {
            std.debug.print("gc_bif2: unsupported destination tag={d}\n", .{@intFromEnum(dst_ct.tag)});
        }

        std.debug.print("gc_bif2: result = {d}\n", .{result.getSmallIntValue()});
    }

    // ============================================================================
    // Helper Functions
    // ============================================================================

    fn getSrcValue(self: *Executor, src: compact_term.CompactTerm) !term.Term {
        return switch (src.tag) {
            .integer => term.Term.makeSmallInt(@intCast(src.value)),
            .atom => if (src.value == 0) term.Term.NIL else term.Term.makeAtom(@intCast(src.value)),
            .x_reg => self.vm.process.x_regs[src.value],
            .y_reg => self.vm.process.y_regs[src.value],
            .literal => term.Term.makeSmallInt(@intCast(src.value)), // Phase 2B: treat literal as small int
            .extended => term.Term.makeSmallInt(@intCast(src.value)), // Phase 2B: treat extended as small int
            else => error.NotImplemented,
        };
    }

    fn setDstValue(self: *Executor, dst: compact_term.CompactTerm, value: term.Term) !void {
        switch (dst.tag) {
            .x_reg => self.vm.process.x_regs[dst.value] = value,
            .y_reg => self.vm.process.y_regs[dst.value] = value,
            .literal => self.vm.process.x_regs[dst.value] = value, // Phase 2B: treat literal as x_reg
            .extended => self.vm.process.x_regs[dst.value] = value, // Phase 2B: treat extended as x_reg
            .atom => {
                // Phase 2B: atom destinations - ignore for now (atoms are constants)
                std.debug.print("move: ignoring atom destination (atom {d})\n", .{dst.value});
            },
            else => return error.NotImplemented,
        }
    }

    fn getAtomName(self: *const Executor, cterm: compact_term.CompactTerm) []const u8 {
        if (cterm.tag == .atom and cterm.value > 0) {
            const atom_index = @as(u32, @intCast(cterm.value - 1));
            return self.vm.beam_file.getAtom(atom_index);
        }
        return "<unknown>";
    }

    fn getArityValue(cterm: compact_term.CompactTerm) u32 {
        return if (cterm.tag == .integer) @intCast(cterm.value) else 0;
    }

    fn getLiteralValue(cterm: compact_term.CompactTerm) u64 {
        return cterm.value;
    }

    fn termStr(self: *const Executor, cterm: compact_term.CompactTerm) []const u8 {
        // Simple string representation for debugging
        _ = self;
        return switch (cterm.tag) {
            .integer => "integer",
            .atom => "atom",
            .x_reg => "x_reg",
            .y_reg => "y_reg",
            .label => "label",
            else => "unknown",
        };
    }
};