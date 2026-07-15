# Project Milestones

## Overview

This document defines the development milestones for zvm, a BEAM-compatible virtual machine implementation in Zig. Each milestone represents a significant phase of development with specific deliverables and measurable exit criteria based on OTP test suite compatibility.

**Timeline**: 30 months for 95% OTP compatibility
**Approach**: Incremental development with strict dependency ordering
**Philosophy**: Single scheduler before SMP, correctness before performance

---

## Phase 1 - Foundations (Months 1-3)

### Objective
Establish term representation and BEAM file loading infrastructure.

### Status
📋 **PLANNING** - Target: 2026-10-31

### Deliverables

#### 1.1 Term Representation
- [ ] Tagged immediate terms (SmallInt, Atom, PID, Port, Ref)
- [ ] Boxed term pointers with headers
- [ ] Term header format with arity, type tag, GC mark bits
- [ ] Literal pointer tagging for constant pool
- [ ] External term format compatibility

#### 1.2 Global Tables
- [ ] Atom table (global, lock-free, never GC'd)
- [ ] Literal table
- [ ] String table
- [ ] Import/export table resolution

#### 1.3 BEAM File Loader
- [ ] BEAM file format parser (all chunk types)
- [ ] Code chunk parsing with instruction decoding
- [ ] Atom table chunk processing
- [ ] Import/export resolution
- [ ] Line table for debugging

#### 1.4 Disassembler
- [ ] Opcode decoder for all OTP 28 opcodes (~160 opcodes)
- [ ] Pretty-print instructions with operands
- [ ] Disassemble all files in erts, kernel, stdlib
- [ ] Dump atoms, imports, exports, code

### Exit Criteria
- [ ] Successfully parse all .beam files from OTP 28
- [ ] Disassemble and print all opcodes correctly
- [ ] No crashes when loading kernel and stdlib modules
- [ ] Atom table handles OTP's full atom set
- [ ] Term representation matches BEAM exactly

### Success Metrics
- 100% of .beam chunks parseable
- 160 opcodes identified and documented
- Load time: < 100ms per module

---

## Phase 2 - Interpreter Core (Months 4-6)

### Objective
Build single-process interpreter with core opcodes, no SMP.

### Status
📋 **PLANNING** - Target: 2027-01-31

### Deliverables

#### 2.1 Process Control Block (Minimal)
- [ ] Heap start, heap top, heap limit
- [ ] Stack pointer, stack bottom
- [ ] CP (continuation pointer)
- [ ] I (instruction pointer)
- [ ] X registers (0-1023)
- [ ] Reduction counter
- [ ] Trap state
- [ ] Exception handler stack

#### 2.2 Single Scheduler Loop
- [ ] Single-threaded scheduler
- [ ] Process queue management
- [ ] Context switching
- [ ] Reduction counting
- [ ] Basic scheduling fairness

#### 2.3 Instruction Dispatch
- [ ] Threaded dispatch or switch-based interpreter
- [ ] 40 core opcodes implemented:
  - move, call, return, apply
  - is_eq_exact, is_eq, is_ne_exact
  - jump, label, allocate, deallocate
  - test_heap, allocate_heap, allocate_zero
  - put_list, get_hd, get_tl
  - bif implementations for arithmetic

#### 2.4 Basic Stack Machine
- [ ] Stack frame management
- [ ] Function call/return
- [ ] Exception stack handling
- [ ] Tail call optimization

### Exit Criteria
- [ ] Execute factorial.beam with recursion
- [ ] Integer arithmetic BIFs work correctly
- [ ] Single process runs without GC
- [ ] 40 core opcodes pass unit tests
- [ ] Can run simple recursive functions

### Success Metrics
- Opcode dispatch: < 1ns per simple instruction
- Function call overhead: < 100ns
- Process creation: < 1μs
- No memory leaks in interpreter loop

---

## Phase 3 - Memory Management (Months 7-10)

### Objective
Implement real process memory with stack/heap co-location and binary handling.

### Status
📋 **PLANNING** - Target: 2027-05-31

### Deliverables

#### 3.1 Memory Layout
- [ ] Stack and heap in same allocation
- [ ] Grow toward each other
- [ ] Heap allocation with limits
- [ ] Stack overflow detection
- [ ] Memory accounting

#### 3.2 Garbage Collection
- [ ] Minor copying GC per process
- [ ] Major GC to old heap
- [ ] Root set identification
- [ ] Stack and heap copied together
- [ ] GC integration with reductions

#### 3.3 Binary Handling
- [ ] Refc binaries with reference counting
- [ ] ProcBinaries per process
- [ ] Sub-binary support (no copying)
- [ ] Binary heap GC
- [ ] Binary matching context

#### 3.4 Binary Matching State
- [ ] bs_context in PCB
- [ ] bs_rest tracking
- [ ] bs_save_position, bs_restore_position
- [ ] Binary match instructions
- [ ] Bit syntax operations

#### 3.5 PCB Enhancement
- [ ] Add bsmatch state
- [ ] bs_context, bs_rest, bs_position
- [ ] Binary heap references
- [ ] Memory limit tracking

### Exit Criteria
- [ ] Pass all emulator tests for gc, binary, binary_match, bit_syntax
- [ ] No leaks in binary copy + GC loop
- [ ] Binary matching works for all patterns
- [ ] Sub-binaries don't leak
- [ ] GC pause time < 10ms

### Success Metrics
- GC pause: < 10ms for 1MB heap
- Zero memory leaks in binary tests
- Handle 1M+ allocations per second
- Memory overhead: < 2x of BEAM

---

## Phase 4 - BIFs Tier 1 and Exceptions (Months 11-14)

### Objective
Implement language core with exception handling and trap/yield protocol.

### Status
📋 **PLANNING** - Target: 2027-09-30

### Deliverables

#### 4.1 BIFs Implementation (~400 functions)
- [ ] Arithmetic: +, -, *, /, rem, div, band, bor, bxor, bsl, bsr
- [ ] Type checks: is_integer, is_float, is_atom, is_pid, is_port, is_ref
- [ ] Lists: hd, tl, length, nth, cons
- [ ] Tuples: element, setelement, tuple_size, make_tuple
- [ ] Maps (flatmap): map_get, map_put, is_map
- [ ] Binaries: byte_size, bit_size, split_binary
- [ ] Conversions: list_to_binary, binary_to_list, atom_to_list

#### 4.2 Exception Engine
- [ ] try/catch/throw/error/exit
- [ ] Stacktrace capture (__STACKTRACE__)
- [ ] Error reason normalization
- [ ] Exit signal propagation
- [ ] Exception handler stack

#### 4.3 Trap and Yield Protocol
- [ ] BIF return types: BIF_OK, BIF_TRAP, BIF_ERROR, BIF_YIELD
- [ ] Trap state in PCB
- [ ] Re-entry after trap
- [ ] Yield on reduction exhaustion
- [ ] Context saving for traps

#### 4.4 Bump Reductions Model
- [ ] Reduction costs for BIFs
- [ ] GC costs reductions
- [ ] Bump_reductions implementation
- [ ] Fair scheduling with costs

#### 4.5 Full PCB Fields
- [ ] Complete PCB with all fields
- [ ] Dictionary pointer
- [ ] Links list, monitors list
- [ ] Message queue
- [ ] Priority levels
- [ ] Process flags (trap_exit, etc.)

### Exit Criteria
- [ ] Compile and run Elixir hello world via elixirc
- [ ] Pass 70% of stdlib tests (lists, maps, enums)
- [ ] Exception handling matches BEAM exactly
- [ ] Trap/yield works for yielding BIFs
- [ ] No crashes in exception tests

### Success Metrics
- 400 core BIFs implemented
- Exception handling: 100% compatible
- Trap protocol: no hangs or crashes
- BIF performance: within 10x of BEAM

---

## Phase 5 - Concurrency Primitives (Months 15-18)

### Objective
Implement full OTP process model with SMP scheduler and messaging.

### Status
📋 **PLANNING** - Target: 2028-01-31

### Deliverables

#### 5.1 Full Process Model
- [ ] Complete PCB with all fields
- [ ] Process spawning with spawn_opt
- [ ] Process linking and unlinking
- [ ] Process monitoring
- [ ] Exit signal propagation
- [ ] trap_exit handling

#### 5.2 Message Passing
- [ ] Message queue implementation
- [ ] Send/receive primitives
- [ ] Message copying semantics
- [ ] select_receive with timeout
- [ ] Pattern matching in receive

#### 5.3 SMP Scheduler
- [ ] M:N scheduler with work stealing
- [ ] One run queue per scheduler
- [ ] Dirty schedulers (CPU and I/O)
- [ ] Process migration between schedulers
- [ ] Load balancing

#### 5.4 Time Subsystem
- [ ] Monotonic time
- [ ] Wall clock time
- [ ] erlang:send_after/3
- [ ] erlang:start_timer/3
- [ ] Timer wheel implementation

#### 5.5 System Signals
- [ ] Link signal handling
- [ ] Monitor signal handling
- [ ] EXIT message semantics
- [ ] process_flag(trap_exit)
- [ ] Signal ordering guarantees

#### 5.6 Atomic Operations
- [ ] Atomics for atom table
- [ ] Atomics for ETS
- [ ] Counters implementation
- [ ] Lock-free data structures

### Exit Criteria
- [ ] Boot init, erl_prim_loader, prim_eval
- [ ] Spawn 10k processes doing ping-pong
- [ ] Message passing works without deadlocks
- [ ] SMP scheduler fair scheduling
- [ ] Time operations work correctly

### Success Metrics
- Process creation: < 1μs per process
- Message passing: < 100ns latency
- 100k concurrent processes
- Fair scheduling demonstrated
- No deadlocks in stress tests

---

## Phase 6 - ETS and System (Months 19-22)

### Objective
Implement ETS, code server, and system primitives required for OTP.

### Status
📋 **PLANNING** - Target: 2028-05-31

### Deliverables

#### 6.1 ETS Implementation
- [ ] ETS table types: set, bag, duplicate_bag, ordered_set
- [ ] Access controls: public, private, protected
- [ ] Concurrency: write_concurrency, read_concurrency
- [ ] ETS operations: insert, lookup, delete, select, match
- [ ] Table ownership and heirship

#### 6.2 Persistent Terms
- [ ] persistent_term implementation
- [ ] Global persistent storage
- [ ] Initialization and updates
- [ ] Performance optimization

#### 6.3 Atomics and Counters
- [ ] Full atomic operations
- [ ] Counter implementation
- [ ] Performance-optimized atomics

#### 6.4 Ports and Drivers
- [ ] Port primitives (stub implementation)
- [ ] File operations via port driver
- [ ] inet operations via port driver
- [ ] Port message protocol

#### 6.5 Code Server
- [ ] Old and new code management
- [ ] Code purge (purge/1)
- [ ] check_process_code implementation
- [ ] Module versioning
- [ ] Code loading interface

#### 6.6 Application Boot
- [ ] kernel application startup
- [ ] application:start/2
- [ ] Supervision tree basics
- [ ] application lifecycle

### Exit Criteria
- [ ] Pass 90% of ETS tests
- [ ] Boot kernel application successfully
- [ ] application:start(kernel) works
- [ ] Code server handles hot loading
- [ ] Ports handle basic I/O

### Success Metrics
- ETS operations: within 5x of BEAM
- 90% ETS test pass rate
- Code server: no crashes
- Application boot: < 200ms

---

## Phase 7 - Full Compatibility (Months 23-27)

### Objective
Complete remaining BIFs, full maps implementation, and achieve OTP boot capability.

### Status
📋 **PLANNING** - Target: 2028-10-31

### Deliverables

#### 7.1 Remaining BIFs (~1200 functions)
- [ ] Complete erlang module BIFs
- [ ] lists module functions
- [ ] maps module (full HAMT)
- [ ] binary module functions
- [ ] io module functions
- [ ] file module functions
- [ ] crypto, math, calendar modules

#### 7.2 Maps Full Implementation
- [ ] HAMT-based maps (OTP 26+)
- [ ] Flatmap optimization
- [ ] Map operations performance
- [ ] Map pattern matching

#### 7.3 Binary Matching Optimization
- [ ] Advanced binary matching
- [ ] Binary construction optimization
- [ ] Bit syntax performance
- [ ] Binary context optimization

#### 7.4 Full Boot Sequence
- [ ] erl -noshell boot sequence
- [ ] init process boot
- [ ] prim_eval loading
- [ ] erl_prim_loader
- [ ] Complete boot to shell

#### 7.5 File and Networking
- [ ] Full file operations
- [ ] inet driver functionality
- [ ] crypto via ports
- [ ] Basic networking support

#### 7.6 Hot Code Loading
- [ ] Code swapping at runtime
- [ ] State preservation
- [ ] Process migration to new code
- [ ] Rollback support

### Exit Criteria
- [ ] **Tiered Test Success**:
  - emulator suite: >= 98%
  - stdlib suite: >= 95%
  - kernel suite: >= 90%
  - compiler suite: >= 90%
- [ ] Run Elixir 1.17 hello world
- [ ] Run simple mix project
- [ ] Full boot sequence completes
- [ ] Hot code loading works

### Success Metrics
- 1600 BIFs implemented
- Tiered test criteria met
- Elixir basic programs run
- Hot code swap: < 100ms
- Boot to shell: < 500ms

---

## Phase 8 - Hardening and Performance (Months 28-30)

### Objective
Production hardening, performance optimization, and v1.0 release preparation.

### Status
📋 **PLANNING** - Target: 2029-01-31

### Deliverables

#### 8.1 Performance Optimization
- [ ] Threaded dispatch implementation
- [ ] Superinstructions (i_plus, i_bs_match, etc.)
- [ ] Dirty scheduler optimization
- [ ] CPU and I/O dirty scheduler tuning
- [ ] Memory allocation optimization

#### 8.2 Platform Optimization
- [ ] Linux ARM aarch64 optimizations
- [ ] Cache-friendly data structures
- [ ] SIMD where applicable
- [ ] System call optimization

#### 8.3 Memory Profiling
- [ ] Memory leak detection
- [ ] Heap profiling tools
- [ ] Binary leak sanitization
- [ ] Process memory accounting

#### 8.4 Hardening
- [ ] Stress testing
- [ ] Long-running stability tests
- [ ] Edge case handling
- [ ] Resource limit enforcement
- [ ] Graceful degradation

#### 8.5 Tooling Support
- [ ] Debugger interface
- [ ] Tracing facilities
- [ ] Observer protocol (basic)
- [ ] Performance profiling

#### 8.6 Documentation Complete
- [ ] API documentation
- [ ] User manual
- [ ] Deployment guide
- [ ] Performance guide
- [ ] Troubleshooting guide

### Exit Criteria
- [ ] **Performance**:
  - Interpreter: 5-8x slower than BEAM JIT (realistic)
  - Idle process: < 4KB memory
  - Boot to kernel: < 200ms
- [ ] **Quality**:
  - Zero memory leaks (valgrind/ASAN clean)
  - 99.9% uptime in stress tests
  - No crashes in 1-hour rebar3 run
- [ ] **Compatibility**:
  - Tiered test criteria maintained
  - Elixir 1.17 basic programs run
  - Real-world OTP applications work

### Success Metrics
- Interpreter: 5-8x BEAM JIT performance
- Memory: < 4KB per idle process
- Boot: < 200ms to kernel startup
- Leaks: 0 leaks in sanitizers
- Stability: 99.9% uptime

---

## Timeline Summary

```
Phase 1: Foundations       ████░░░░░░░░░░░░░░░░  0% (Months 1-3)
Phase 2: Interpreter Core  ░░░░░░░░░░░░░░░░░░░░  0% (Months 4-6)
Phase 3: Memory Mgmt      ░░░░░░░░░░░░░░░░░░░░  0% (Months 7-10)
Phase 4: BIFs & Exceptions ░░░░░░░░░░░░░░░░░░░░  0% (Months 11-14)
Phase 5: Concurrency      ░░░░░░░░░░░░░░░░░░░░  0% (Months 15-18)
Phase 6: ETS & System     ░░░░░░░░░░░░░░░░░░░░  0% (Months 19-22)
Phase 7: Full Compat      ░░░░░░░░░░░░░░░░░░░░  0% (Months 23-27)
Phase 8: Hardening        ░░░░░░░░░░░░░░░░░░░░  0% (Months 28-30)

Timeline: July 2026 ───► January 2029 (~30 months)
```

## Key Dependencies

- **Phase 2 → Phase 3**: Single scheduler must work before adding GC
- **Phase 3 → Phase 4**: Memory management must be solid before BIFs
- **Phase 4 → Phase 5**: Core language must work before concurrency
- **Phase 5 → Phase 6**: Concurrency must work before ETS
- **Phase 6 → Phase 7**: System must work before full compatibility
- **Phase 7 → Phase 8**: Compatibility must work before optimization

## Critical Path

The critical path for BEAM compatibility is:
1. **Term representation** (Phase 1) → affects everything
2. **Memory management** (Phase 3) → affects stability
3. **Exception handling** (Phase 4) → affects language correctness
4. **Concurrency** (Phase 5) → affects OTP applications
5. **ETS** (Phase 6) → affects kernel boot

## Risk Mitigation

- **Binary handling**: Biggest risk, allocate extra time in Phase 3
- **Exception semantics**: Complex, test extensively in Phase 4
- **Boot sequence**: Undocumented, reserve debugging time in Phase 7
- **Performance**: May miss aggressive targets, have realistic fallbacks

---

**Document Version**: 2.0
**Last Updated**: 2026-07-15
**Total Duration**: 30 months
**Current Phase**: Planning Phase 1
**Target Completion**: January 2029
