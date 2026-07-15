# Architecture

## Overview

This document describes the technical architecture of zvm, a BEAM-compatible virtual machine implementation in Zig. The architecture is designed to achieve 100% compatibility with the Erlang BEAM VM while leveraging Zig's safety guarantees and performance characteristics.

## 1. System Architecture

### 1.1 High-Level Architecture

```
┌──────────────────────────────────────────────────────────┐
│                   Erlang/Elixir Applications              │
├──────────────────────────────────────────────────────────┤
│                    .beam Bytecode Files                   │
├──────────────────────────────────────────────────────────┤
│                      zvm Runtime                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │                 Process Management                 │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐   │  │
│  │  │  Scheduler │  │  Processes │  │  Mailboxes │   │  │
│  │  └────────────┘  └────────────┘  └────────────┘   │  │
│  ├────────────────────────────────────────────────────┤  │
│  │              Memory Management                      │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐   │  │
│  │  │ Allocator  │  │     GC     │  │Binary Heap │   │  │
│  │  └────────────┘  └────────────┘  └────────────┘   │  │
│  ├────────────────────────────────────────────────────┤  │
│  │              Execution Engine                        │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐   │  │
│  │  │ Instruction │  │   Stack    │  │  Register  │   │  │
│  │  │  Decoder   │  │   Machine  │  │     VM     │   │  │
│  │  └────────────┘  └────────────┘  └────────────┘   │  │
│  ├────────────────────────────────────────────────────┤  │
│  │              Code Loading & Storage                  │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐   │  │
│  │  │ BEAM Parser│  │Code Server │  │Atom Table  │   │  │
│  │  └────────────┘  └────────────┘  └────────────┘   │  │
│  ├────────────────────────────────────────────────────┤  │
│  │              BIFs & System Interface                 │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐   │  │
│  │  │ Core BIFs  │  │Module BIFs │  │  I/O Sys   │   │  │
│  │  └────────────┘  └────────────┘  └────────────┘   │  │
│  ├────────────────────────────────────────────────────┤  │
│  │              ETS & System                            │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐   │  │
│  │  │    ETS     │  │Persistent  │  │   Ports    │   │  │
│  │  │            │  │   Terms    │  │            │   │  │
│  │  └────────────┘  └────────────┘  └────────────┘   │  │
│  └────────────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────────┤
│                      Zig Runtime                          │
├──────────────────────────────────────────────────────────┤
│                   Operating System                        │
└──────────────────────────────────────────────────────────┘
```

## 2. Core Components

### 2.1 Process Control Block (PCB)

The Process Control Block is the heart of process execution. It must contain ALL of the following fields:

```zig
const Process = struct {
    // Process identification
    pid: Pid,
    registered_name: ?Atom,
    group_leader: Pid,

    // Memory management
    heap: *Term,           // Heap start pointer
    heap_top: *Term,       // Current allocation pointer
    heap_limit: *Term,     // Maximum heap size
    heap_size: usize,      // Total heap allocation
    old_heap: ?*Term,     // Old generation heap
    old_heap_size: usize,

    // Stack management (CRITICAL: stack and heap grow toward each other)
    stack_top: *Term,      // Current stack pointer
    stack_bottom: *Term,   // Stack base
    stack_limit: *Term,    // Stack overflow limit
    stack_start: *Term,    // Original stack allocation

    // Execution state
    i: u32,                // Instruction pointer
    cp: u32,               // Continuation pointer
    // IP will be restored from CP on return

    // Registers
    xregs: [1024]Term,     // X registers (caller-saves, X0-X1023)
    yregs: []Term,         // Y registers (callee-saves, variable size)
    fregs: [10]Term,      // Floating-point registers

    // Scheduling and reductions
    reductions: u32,       // Reduction counter
    fcalls: u32,          // Function call counter
    priority: Priority,    // Process priority (max, high, normal, low)
    status: ProcessStatus, // Process status enum

    // Trap and yield state
    trap_state: TrapState, // Current trap state
    trap_reason: ?Atom,   // Reason for trapping
    trap_args: []Term,    // Saved arguments for trap re-entry

    // Exception handling
    exception_handler_stack: []ExceptionHandler,
    catch_marker: ?*Term, // Current catch marker
    error_reason: ?Term,  // Current error reason

    // Message passing
    msg_queue: *MessageQueue,
    msg_in_queue: ?*Message,
    msg_save: ?*Message,  // Saved message during select_receive

    // Process links and monitoring
    links: []Pid,          // Linked processes
    monitors: []Monitor,   // Process monitors
    being_monitored_by: []Pid,

    // Process flags and state
    flags: ProcessFlags,  // trap_exit, save_trap, etc.
    dictionary: Map,       // Process dictionary
    refc_binary_references: []RefcBinary,

    // Binary matching state
    bs_match_state: BinaryMatchState,
    bs_context: ?*BinaryContext,
    bs_rest: ?*BinaryRest,
    bs_position: usize,

    // Time and timers
    start_time: u64,      // Process start time
    timeout_target: ?u64, // Next timeout target

    // Memory limits and accounting
    memory_limit: usize,
    memory_used: usize,
    max_heap_size: usize,
};

const ProcessStatus = enum(u8) {
    runnable,
    waiting,
    running,
    exiting,
    garbage_collecting,
    suspended,
};

const TrapState = enum(u8) {
    none,
    trap_yield,          // Yielding for reduction exhaustion
    trap_timeout,        // Timeout in receive
    trap_bif,            // BIF needs to trap
    trap_gc,             // GC requested
};

const ProcessFlags = packed struct(u32) {
    trap_exit: bool,     // trap_exit flag
    save_trap: bool,     // Save trap state
    binary_heap: bool,   // Using binary heap
    floating_point: bool,// Using FPU
    heap_allocated: bool,// Heap allocated
    _padding: u27,
};
```

### 2.2 Memory Layout

**CRITICAL**: Stack and heap share the same memory block and grow toward each other.

```
┌─────────────────────────────────────────┐
│         Process Memory Block           │
├─────────────────────────────────────────┤
│  ┌─────────────────────────────────┐   │
│  │         Heap (grows up)         │   │
│  │  ┌─────────────────────────┐    │   │
│  │  │  heap_top →  ────────────│─── │   │
│  │  │                         │    │   │
│  │  │  Allocated Terms        │    │   │
│  │  │                         │    │   │
│  │  └─────────────────────────┘    │   │
│  │           ↑ ↑ ↑                  │   │
│  │           │ │ │                  │   │
│  │  ┌────────┴─┴─┴─────────────┐   │   │
│  │  │   Free Space            │   │   │
│  │  └────────┬─┬─┬─────────────┘   │   │
│  │           │ │ │                  │   │
│  │  ┌────────┴─┴─┴─────────────┐   │   │
│  │  │                         │    │   │
│  │  │  Stack (grows down)     │    │   │
│  │  │  ───────────────── ← stack_top │   │
│  │  └─────────────────────────┘    │   │
│  │         stack_bottom             │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

**Key implications**:
- GC must copy BOTH stack and heap together
- Stack overflow is detected by checking stack_top vs heap_top
- Memory allocation checks both heap_top and stack_top limits
- This design is CRITICAL for correct GC implementation

### 2.3 Term Representation

**BEAM 64-bit Term Layout** (must match exactly):

```zig
const Term = struct {
    value: usize,

    // Tagged immediates (low bits indicate type)
    const TAG_BITS: u4 = 0xF;
    const TAG_MASK: usize = 0xF;

    // Immediate term tags
    const SMALL_INT_TAG: u4 = 0x3;   // 0011
    const ATOM_TAG: u4 = 0xB;        // 1011
    const PID_TAG: u4 = 0xD;         // 1101
    const PORT_TAG: u4 = 0xE;        // 1110
    const REF_TAG: u4 = 0xF;         // 1111

    // Boxed pointer (low bits 00)
    const BOXED_TAG: u4 = 0x0;       // 0000

    // Literal pointer (special tag for constant pool)
    const LITERAL_TAG: u4 = 0x2;     // 0010

    fn is_small_int(self: Term) bool {
        return (self.value & TAG_MASK) == SMALL_INT_TAG;
    }

    fn is_atom(self: Term) bool {
        return (self.value & TAG_MASK) == ATOM_TAG;
    }

    fn is_boxed(self: Term) bool {
        return (self.value & TAG_MASK) == BOXED_TAG;
    }

    fn is_literal(self: Term) bool {
        return (self.value & TAG_MASK) == LITERAL_TAG;
    }

    fn get_small_int_value(self: Term) i64 {
        return @as(i64, @bit_cast(@intCast(self.value >> 4)));
    }

    fn make_small_int(value: i64) Term {
        return Term{ .value = (@as(usize, @bit_cast(@intCast(value))) << 4) | SMALL_INT_TAG };
    }

    fn get_boxed_ptr(self: Term) *Term {
        return @as(*Term, @ptrFromInt(self.value & ~@as(usize, TAG_MASK)));
    }
};

// Boxed term header format
const Header = struct {
    value: usize,

    const HEADER_ARITY_MASK: usize = 0x7FF;
    const HEADER_TYPE_MASK: usize = 0xF;
    const HEADER_TYPE_SHIFT: u5 = 12;

    fn get_arity(self: Header) u32 {
        return @as(u32, @int_cast((self.value >> HEADER_TYPE_SHIFT) & HEADER_ARITY_MASK));
    }

    fn get_type(self: Header) HeaderType {
        return @as(HeaderType, @enumFromInt((self.value >> HEADER_TYPE_SHIFT) & HEADER_TYPE_MASK));
    }
};

const HeaderType = enum(u4) {
    tuple = 0x0,
    big_int = 0x3,
    ref = 0x4,
    fun = 0x5,
    external_fun = 0x6,
    binary = 0x8,
    map = 0x9,
    // ... more types
};
```

### 2.4 Binary Handling

**The most complex memory subsystem** - requires careful reference counting and sub-binary support.

```zig
// Reference-counted binary (shared across processes)
const RefcBinary = struct {
    ref_count: Atomic(u32),
    data: [*]u8,
    size: usize,
    orig_size: usize,

    fn increment_ref(self: *RefcBinary) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    fn decrement_ref(self: *RefcBinary) void {
        if (self.ref_count.fetchSub(1, .seq_cst) == 1) {
            // Last reference - free the binary
            self.deinit();
        }
    }
};

// Process-specific binary reference
const ProcBinary = struct {
    refc: *RefcBinary,      // Shared reference
    offset: usize,          // Offset into refc binary
    size: usize,            // Size of this view
    owner: Pid,             // Owning process

    fn create(self: *ProcBinary, refc: *RefcBinary) void {
        self.refc = refc;
        refc.increment_ref();
    }

    fn destroy(self: *ProcBinary) void {
        if (self.refc) |refc| {
            refc.decrement_ref();
        }
    }
};

// Sub-binary (no copying, points into parent)
const SubBinary = struct {
    parent: union {
        refc: *RefcBinary,
        proc_bin: *ProcBinary,
    },
    offset: usize,
    size: usize,
    is_byte_aligned: bool,
};

// Binary matching context (in PCB)
const BinaryMatchState = struct {
    context: ?*BinaryContext,
    rest: ?*BinaryRest,
    position: usize,
    saved_position: usize,

    fn save_position(self: *BinaryMatchState) void {
        self.saved_position = self.position;
    }

    fn restore_position(self: *BinaryMatchState) void {
        self.position = self.saved_position;
    }
};
```

### 2.5 Scheduler Architecture

```zig
const Scheduler = struct {
    // Scheduling state
    schedulers: []SchedulerThread,
    num_schedulers: usize,
    num_cpus: usize,

    // Run queues (one per scheduler for work stealing)
    run_queues: []RunQueue,

    // Dirty schedulers
    cpu_dirty_scheduler: ?*Scheduler,
    io_dirty_scheduler: ?*Scheduler,

    // Process accounting
    total_processes: usize,
    max_processes: usize,

    // Load balancing
    migration_queue: []Pid,
    balancing_interval: u64,
};

const RunQueue = struct {
    // Priority levels
    max_queue: PriorityQueue(Process),
    high_queue: PriorityQueue(Process),
    normal_queue: PriorityQueue(Process),
    low_queue: PriorityQueue(Process),

    // Work stealing
    len: usize,
    migration_flag: bool,

    // Statistics
    total_reductions: u64,
    context_switches: u64,
};

const SchedulerThread = struct {
    id: usize,
    run_queue: *RunQueue,
    current_process: ?*Process,

    // Scheduling loop
    fn schedule(self: *SchedulerThread) void {
        while (true) {
            if (self.select_next_process()) |proc| {
                self.execute_process(proc);
            } else {
                // No runnable processes - sleep or steal
                self.steal_work();
            }
        }
    }

    fn execute_process(self: *SchedulerThread, proc: *Process) void {
        const reductions_before = proc.reductions;
        self.current_process = proc;

        // Execute until reductions exhausted
        while (proc.reductions > 0) {
            self.execute_instruction(proc);

            // Check for traps
            if (proc.trap_state != .none) {
                self.handle_trap(proc);
                break;
            }

            proc.reductions -= 1;
        }

        self.current_process = null;
        proc.fcalls = 0; // Reset function call counter
    }
};
```

### 2.6 Trap and Yield Protocol

**CRITICAL**: All BIFs must support trapping for yielding and long operations.

```zig
const BifResult = enum(u8) {
    ok,        // BIF completed successfully, result in xregs[0]
    trap,      // BIF needs to trap (save state and retry later)
    error,     // BIF failed with error
    yield,     // BIF yielded (reductions exhausted)
};

const BifTrap = struct {
    trap_function: *const fn(*Process) BifResult,
    trap_args: []Term,
    trap_state: TrapState,
};

// BIF implementation example with trap support
fn bif_binary_to_term(proc: *Process) BifResult {
    const binary_arg = proc.xregs[0];

    // Check if we have the full binary data available
    if (!is_binary_fully_available(binary_arg)) {
        // Need to trap and wait for more data
        proc.trap_state = .trap_bif;
        proc.trap_args = &[_]Term{binary_arg};
        return .trap;
    }

    // Process the binary
    const result = convert_binary_to_term(binary_arg);
    proc.xregs[0] = result;
    return .ok;
}

// Interpreter loop must check traps
fn execute_instruction(proc: *Process) void {
    const instr = decode_instruction(proc.i);

    // Execute instruction
    switch (instr.opcode) {
        .call_bif => {
            const bif_result = execute_bif(proc, instr.bif_index);
            switch (bif_result) {
                .ok => { /* Continue execution */ },
                .trap => { /* Save state and yield process */ },
                .error => { /* Handle error */ },
                .yield => { /* Yield to scheduler */ },
            }
        },
        // ... other opcodes
    }

    // Check for trap before next instruction
    if (proc.trap_state != .none) {
        handle_trap(proc);
    }
}
```

## 3. Instruction Set Architecture

### 3.1 Core Opcodes (Phase 2 - 40 opcodes)

```zig
const Opcode = enum(u8) {
    // Control flow
    label = 0x01,
    line = 0x02,
    func_info = 0x03,

    // Stack and heap management
    allocate = 0x04,
    allocate_heap = 0x05,
    allocate_zero = 0x06,
    test_heap = 0x07,
    deallocate = 0x08,

    // Function calls
    call = 0x09,
    call_last = 0x0A,
    call_only = 0x0B,
    call_ext = 0x0C,
    call_ext_last = 0x0D,

    // Returns
    return = 0x0E,

    // Jumps
    jump = 0x0F,
    jump_if_val = 0x10,

    // Moves
    move = 0x11,
    move_x2 = 0x12,
    move_return = 0x13,

    // Comparisons
    is_eq_exact = 0x14,
    is_eq = 0x15,
    is_ne_exact = 0x16,
    is_ne = 0x17,
    is_lt = 0x18,
    is_ge = 0x19,
    is_gt = 0x1A,
    is_le = 0x1B,

    // List operations
    put_list = 0x1C,
    get_hd = 0x1D,
    get_tl = 0x1E,

    // Tuple operations
    put_tuple = 0x1F,
    get_tuple_element = 0x20,

    // BIF calls
    call_bif = 0x21,
    gc_bif = 0x22,

    // ... more opcodes
};
```

### 3.2 Instruction Dispatch

```zig
// Threaded dispatch approach (Zig-friendly)
const InstructionHandler = *const fn(*Process, *Instruction) void;

const instruction_table: [256]InstructionHandler = blk: {
    var table: [256]InstructionHandler = undefined;
    table[@intFromEnum(Opcode.move)] = handle_move;
    table[@intFromEnum(Opcode.call)] = handle_call;
    table[@intFromEnum(Opcode.is_eq_exact)] = handle_is_eq_exact;
    // ... fill in all handlers
    break :blk table;
};

fn execute_instruction(proc: *Process) void {
    const instr = decode_instruction(proc.i);
    const handler = instruction_table[@intFromEnum(instr.opcode)];
    handler(proc, &instr);
}
```

## 4. BEAM File Format

### 4.1 BEAM File Structure

```
┌─────────────────────────────────────────┐
│              BEAM File                  │
├─────────────────────────────────────────┤
│  Header: "FOR1" <size> "BEAM"          │
├─────────────────────────────────────────┤
│  Chunks:                                │
│  ┌─────────────────────────────────┐   │
│  │  Code - Bytecode instructions    │   │
│  │  Atom - Atom table               │   │
│  │  Str - String table              │   │
│  │  Imp - Import table              │   │
│  │  Exp - Export table              │   │
│  │  Lit - Literal table             │   │
│  │  Fun - Function table            │   │
│  │  AtU8 - UTF-8 atom table         │   │
│  │  Line - Line number table        │   │
│  │  Type - Type specification       │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

### 4.2 Code Chunk Format

```zig
const CodeChunk = struct {
    info: CodeInfo,
    instructions: []u8,
    labels: []u32,

    // Instruction encoding
    fn decode_instruction(code: []const u8, ip: u32) Instruction {
        const opcode = @as(Opcode, @enumFromInt(code[ip]));
        const num_args = opcode.get_num_args();

        var instr = Instruction{
            .opcode = opcode,
            .args = undefined,
        };

        var offset: u32 = 1;
        for (0..num_args) |i| {
            const arg_type = opcode.get_arg_type(i);
            instr.args[i] = decode_arg(code, ip + offset, arg_type);
            offset += arg_type.size();
        }

        return instr;
    }
};
```

## 5. Implementation Strategy

### 5.1 Development Phases

1. **Phase 1**: Term representation, BEAM loader, disassembler
2. **Phase 2**: Single scheduler, core opcodes, basic PCB
3. **Phase 3**: Memory management (stack+heap co-location), GC, binaries
4. **Phase 4**: BIFs, exceptions, trap/yield protocol
5. **Phase 5**: SMP scheduler, concurrency, messaging
6. **Phase 6**: ETS, persistent terms, code server
7. **Phase 7**: Remaining BIFs, full boot, hot loading
8. **Phase 8**: Optimization, hardening, production

### 5.2 Testing Strategy

```
Test Pyramid:
┌─────────────────────────────────────┐
│  OTP Test Suites (Compatibility)    │
├─────────────────────────────────────┤
│  Integration Tests (Components)     │
├─────────────────────────────────────┤
│  Unit Tests (Data Structures)        │
├─────────────────────────────────────┤
│  Property Tests (Semantics)          │
├─────────────────────────────────────┤
│  Performance Tests (Benchmarks)      │
└─────────────────────────────────────┘
```

## 6. Critical Implementation Details

### 6.1 GC Implementation Notes

- Stack and heap MUST be copied together in minor GC
- Write barriers needed for generational promotion
- Binary reference counting integrated with GC
- GC costs reductions (bump_reductions model)

### 6.2 Exception Handling

- Exception handler stack in PCB
- try/catch/end markers
- __STACKTRACE__ capture
- Error reason normalization
- Exit signal propagation

### 6.3 Message Passing

- Message copying semantics (except binaries)
- Message queue with pattern matching
- select_receive with timeout
- Trap on timeout
- Process links and monitors

### 6.4 Distribution (v2+)

- External term format
- Node discovery and EPMD
- Distributed messaging
- Node monitoring
- (Not in v1.0)

---

**Document Version**: 2.0
**Last Updated**: 2026-07-15
**Status**: Design Phase
**References**:
- The BEAM Book: https://beam-book.org
- OTP Internal Docs: erts/emulator/internal_doc
- BEAM Source: erl_process.h, beam_emu.c
