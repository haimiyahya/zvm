# Project Scope

## Executive Summary

**zvm** is a complete reimplementation of the Erlang BEAM (Bogdan/Björn Erlang Abstract Machine) virtual machine written in Zig. The project aims to achieve 100% compatibility with the official BEAM VM, capable of loading and executing bytecode compiled by the real Erlang compiler without modification.

### Primary Objective

Create a single, minimal binary that can replace the entire Erlang runtime system while maintaining full compatibility with existing Erlang/Elixir applications.

## 1. Project Definition

### 1.1 Core Mission

**Mission Statement**: To provide a BEAM-compatible virtual machine implementation that offers:

- **100% Bytecode Compatibility**: Run unmodified Erlang-compiled bytecode
- **Single Binary Deployment**: All functionality in one self-contained executable
- **Minimal Footprint**: Optimized for size and resource efficiency
- **Performance Parity**: Realistic performance targets (5-8x BEAM JIT for v1.0)
- **Modern Tooling**: Built with Zig's safety guarantees and tooling

### 1.2 Critical Subsystems Required for Compatibility

The following subsystems are **mandatory** for BEAM compatibility and OTP application support:

#### A. Code Loading and Execution
- BEAM file format parser (all chunk types)
- Atom table (global, lock-free, never GC'd until OTP 26+)
- Literal table, String table, Line table
- Import/Export resolution
- Module loading with code_server semantics
- Function call protocol

#### B. Hot Code Loading
- Old and new code management
- Code purge with `purge/1`
- `check_process_code/2` implementation
- This is **core for OTP**, not a future feature

#### C. ETS and Persistent Terms
- ETS tables: set, bag, duplicate_bag, ordered_set
- Access controls: public, private, protected
- Concurrency: write_concurrency, read_concurrency
- persistent_term storage
- atomics and counters
- **Huge amount of OTP depends on ETS**

#### D. Binaries (Most Complex Memory Subsystem)
- Refc binaries with reference counting
- ProcBinaries per process
- Sub-binaries (no copying)
- Binary matching context (bs_context, bs_rest)
- Binary heap GC
- **This is the hardest memory subsystem**

#### E. Maps
- HAMT-based maps (OTP 26+)
- Flatmap optimization for small maps
- Map operations and pattern matching
- Separate from general term storage

#### F. Distribution (Explicit v2.0 Feature)
- External Term Format encode/decode
- Distribution protocol
- Node monitoring
- **Stub implementation in v1.0, full in v1.2**

#### G. Ports, Port Drivers, NIFs
- Port primitives for I/O
- Basic file and inet operations
- **NIF stub in v1.0** (returns `nif_not_loaded`)
- Full enif compatibility in v1.2

#### H. Time and BIF Subsystem
- Monotonic time and wall clock
- `erlang:send_after/3`, `erlang:start_timer/3`
- **~1600 BIF functions** total
- Tiered BIF implementation (400 in v1.0)

#### I. Link, Monitor, and System Signals
- Exit signals and propagation
- `process_flag(trap_exit)`
- Links and monitors
- EXIT message semantics
- **This is core to OTP, not optional**

#### J. Exception and Stacktrace Engine
- try/catch/throw/error/exit
- Stacktrace capture (`__STACKTRACE__`)
- Error reason normalization
- Exception handler stack

### 1.3 In-Scope Deliverables

#### Core VM Components

**1. Process Management**
- Lightweight process model (~2KB minimum, 3-4KB with accounting)
- Process spawning and termination
- Process mailbox and message passing
- Process linking and monitoring
- SMP scheduler with M:N threading
- Priority scheduling (max, high, normal, low)
- Dirty schedulers (CPU and I/O)

**2. Memory Management**
- Stack and heap co-location (grow toward each other)
- Generational garbage collection
- Per-process heaps with shared binary heap
- Write barriers for generational promotion
- Memory limits and accounting

**3. Code Loading & Storage**
- BEAM file format parsing
- Module loading and resolution
- Code server with hot code loading
- Atom table management
- Literal table and constant pool

**4. Execution Engine**
- BEAM instruction decoding (~160 opcodes)
- Stack machine implementation
- Register allocation (X0-X1023)
- Function calling conventions
- Exception handling and stacktraces

**5. Pattern Matching**
- Pattern matching compilation
- Runtime pattern matching
- Guard clause evaluation
- Clause selection

**6. Built-In Functions (BIFs)**
- Tier 1: ~400 core BIFs (arithmetic, type checks, lists, tuples)
- Tier 2: ~1200 additional BIFs (full compatibility)
- BIF trap and yield protocol
- Reduction cost modeling

**7. ETS & System**
- ETS implementation with all table types
- Persistent terms and atomics
- Counters and shared memory
- Code server with purge functionality

**8. Error Handling**
- Process exit signals
- Exception propagation
- Supervision tree support
- Logger implementation

**9. I/O System**
- Standard I/O
- File operations via ports
- Socket I/O via inet driver
- Port communication protocol

**10. Tooling**
- Debugger interface
- Tracing facilities
- Observer protocol (basic)
- Profiling support

### 1.4 Explicit v1.0 Non-Goals

The following are explicitly **out of scope for v1.0**:

#### Distribution & Networking
- **No full node clustering**
- **No EPMD implementation**
- External term format encode/decode **yes**, but no distributed messaging
- Distribution protocols: v1.2+

#### JIT Compilation
- **No JIT or native code compilation**
- Interpreter-only approach
- Performance target: 5-8x BEAM JIT (realistic for interpreter)
- v1.5 may include threaded dispatch and superinstructions

#### NIFs (Native Implemented Functions)
- **No full NIF support in v1.0**
- Implement stub that returns `nif_not_loaded`
- Full enif compatibility: v1.2

#### HiPE (High Performance Erlang)
- **No HiPE native code support**
- HiPE is deprecated in modern OTP anyway

#### Advanced Tracing
- **No DTrace or perf tracing integration**
- Basic tracing yes, deep system profiling: v1.5+

#### Advanced Optimization
- **No superinstructions in v1.0**
- **No threaded dispatch in v1.0**
- These come in optimization phases (v1.5+)

## 2. Technical Context

### 2.1 BEAM VM Architecture

```
Application Layer (Erlang/Elixir Code)
           ↓
    .beam Bytecode
           ↓
┌───────────────────────────────────┐
│         zvm Components            │
├───────────────────────────────────┤
│  Process Management & Scheduler   │
│  Memory Management & GC            │
│  Code Loading & Hot Code Swap     │
│  Pattern Matching & Guards         │
│  BIFs & System Interfaces         │
│  ETS & Persistent Terms           │
│  Error Handling & Supervision    │
│  Ports & I/O (basic)              │
└───────────────────────────────────┘
           ↓
     Zig Runtime
           ↓
    Operating System
```

### 2.2 Key BEAM Concepts

**Processes (Actors)**
- Extremely lightweight (2KB minimum, 3-4KB with accounting)
- Isolated memory spaces
- Asynchronous message passing
- Preemptive scheduling with reduction counting
- Priority levels and fair scheduling

**Memory Model**
- Stack and heap in same allocation, growing toward each other
- Per-process heaps (generational GC)
- Copy semantics for most data
- Binary heap shared across processes
- Reference counting for binaries

**Scheduling**
- M:N scheduler (M user processes, N OS threads)
- One run queue per scheduler with work stealing
- Dirty schedulers for CPU-bound and I/O operations
- Reduction counting for fairness
- Process migration between schedulers

**Code Structure**
- Modules with function exports
- Label-based addressing
- Instruction encoding (~160 opcodes)
- Metadata (exports, imports, atoms, literals)

### 2.3 Technology Stack

**Core Technologies**
- **Language**: Zig (>= 0.14.0)
- **Build System**: Zig native build
- **Testing**: Zig test framework + OTP compatibility tests
- **Target Platforms**: Linux (primary), ARM aarch64

**External Dependencies**
- None for core VM (self-contained)
- Optional: system libraries for specific BIFs

## 3. Scope Boundaries

### 3.1 Version 1.0 Scope

**Minimum Viable Product** for zvm 1.0:

- ✅ Basic build infrastructure
- ✅ BEAM file parsing and disassembly
- ⏳ Process management (spawn, exit, messages)
- ⏳ SMP scheduler with work stealing
- ⏳ Memory allocation and GC (stack+heap co-location)
- ⏳ Binary handling (Refc, ProcBinary, SubBinary)
- ⏳ Core instruction execution (~160 opcodes)
- ⏳ Essential BIFs (~400 functions)
- ⏳ Pattern matching and guards
- ⏳ Basic I/O (via ports)
- ⏳ Hot code loading
- ⏳ ETS (set, bag, duplicate_bag, ordered_set)
- ⏳ Exception handling and stacktraces
- ⏳ Error handling and supervision
- ⏳ Time subsystem

**Explicitly NOT in v1.0**:
- ❌ Distribution and clustering
- ❌ JIT compilation
- ❌ Full NIF support (stub only)
- ❌ HiPE native code
- ❌ Advanced profiling and tracing

### 3.2 Success Definition

**zvm 1.0 Success Criteria**:
- Can boot `init`, `erl_prim_loader`, `prim_eval`
- Can run Elixir 1.17 hello world
- Can run simple mix projects
- Tiered test success:
  - emulator suite: >= 98%
  - stdlib suite: >= 95%
  - kernel suite: >= 90%
  - compiler suite: >= 90%
- No memory leaks in sanitizers
- Realistic performance (5-8x BEAM JIT)

### 3.3 Future Scope (v1.2+)

**Post-1.0 Features**:
- Distribution capabilities
- Full NIF support
- Advanced optimization (threaded dispatch, superinstructions)
- Extended profiling and debugging
- Cross-platform support beyond Linux

## 4. Implementation Timeline

### 4.1 Overall Timeline

**Total Duration**: 30 months for 95% OTP compatibility

**Development Phases**:
1. **Phase 1** (Months 1-3): Foundations - Term representation, BEAM loader, disassembler
2. **Phase 2** (Months 4-6): Interpreter Core - Single scheduler, core opcodes
3. **Phase 3** (Months 7-10): Memory Management - GC, binaries, stack/heap co-location
4. **Phase 4** (Months 11-14): BIFs Tier 1 - Core language, exceptions, trap/yield
5. **Phase 5** (Months 15-18): Concurrency - SMP scheduler, messaging, system signals
6. **Phase 6** (Months 19-22): ETS & System - ETS, code server, application boot
7. **Phase 7** (Months 23-27): Full Compatibility - Remaining BIFs, full boot, hot loading
8. **Phase 8** (Months 28-30): Hardening - Optimization, stability, production readiness

### 4.2 Critical Path

The critical path for BEAM compatibility is:
1. **Term representation** (Phase 1) → affects everything
2. **Memory management** (Phase 3) → affects stability and binary handling
3. **Exception handling** (Phase 4) → affects language correctness
4. **Concurrency** (Phase 5) → affects OTP applications
5. **ETS** (Phase 6) → affects kernel boot

### 4.3 Risk Areas

**High Risk**:
- Binary handling and GC interaction (3+ months for leak-free implementation)
- Exception semantics and stacktraces (complex, edge cases)
- Boot sequence (undocumented magic)
- BIF trap and yield protocol (must be designed from start)

**Medium Risk**:
- Maps implementation (HAMT complex)
- Performance targets (may miss aggressive goals)
- Hot code loading (subtle bugs)

**Low Risk**:
- BEAM file parsing (well-specified)
- Basic instruction execution
- Process structure

## 5. Compatibility Requirements

### 5.1 BEAM Compatibility

**Must Support**:
- All BEAM opcodes (~160 total)
- Standard data types
- Process semantics exactly
- Memory model with stack/heap co-location
- Error handling precisely
- Code loading format
- Hot code swapping

**Test Compatibility**:
- OTP test suite (emulator, stdlib, kernel, compiler)
- Standard library compatibility
- Third-party package tests

### 5.2 Version Compatibility

**Target BEAM Version**: OTP 28 (current stable)
**Bytecode Format**: Match official BEAM specification exactly
**API Compatibility**: Drop-in replacement capability for non-distributed applications

## 6. Success Metrics

### 6.1 Compatibility Metrics
- BEAM opcode coverage: 100%
- OTP test suite: tiered success criteria
- Standard library compatibility: >= 90%
- Elixir 1.17 compatibility: basic programs work

### 6.2 Performance Metrics
- Process creation latency: < 1μs
- Message passing latency: < 100ns
- Interpreter vs BEAM JIT: 5-8x slower (realistic)
- Memory overhead: < 4KB per idle process
- Boot to kernel: < 200ms

### 6.3 Quality Metrics
- Memory leaks: 0 (valgrind/ASAN clean)
- Crash rate: Equal or better than BEAM
- Code coverage: >= 80%
- Stability: 99.9% uptime in stress tests

## 7. Risk Mitigation

### 7.1 Technical Risks

**Binary Handling (Highest Risk)**
- Allocate extra time in Phase 3
- Start with simple binary handling, add complexity gradually
- Extensive testing with sanitizers
- Reference implementation study

**Exception Semantics**
- Test extensively in Phase 4
- Document all edge cases
- Compare behavior with BEAM on real programs

**Boot Sequence**
- Reserve debugging time in Phase 7
- Study OTP boot process carefully
- Incremental boot testing

**Performance**
- Have realistic fallback targets
- Optimize in Phase 8, not before
- Accept interpreter-only limitations

### 7.2 Mitigation Strategies

- Incremental development and testing
- Regular compatibility testing against OTP
- Performance benchmarking at each phase
- Code review and validation
- Reference to BEAM source code (erl_process.h, beam_emu.c)

## 8. Scope Governance

### 8.1 Scope Change Process

1. **Proposal**: Document change request with rationale
2. **Impact Analysis**: Assess timeline and compatibility impact
3. **Stakeholder Review**: Get approval from maintainers
4. **Documentation Update**: Revise scope documents
5. **Communication**: Inform team of changes

### 8.2 Scope Validation

- Monthly scope reviews
- Compatibility assessment
- Technical debt evaluation
- Market relevance check

### 8.3 Non-Goal Enforcement

**v1.0 Non-Goals are HARD boundaries**:
- Distribution: Stub only, defer to v1.2
- JIT: Explicitly interpreter-only for v1.0
- NIFs: Stub implementation returning error
- HiPE: Not planned (deprecated in OTP)

**If scope creep threatens timeline**:
- Re-evaluate priorities
- Consider deferring to v1.2
- Maintain 30-month commitment

## 9. Success Criteria

### 9.1 Must-Have Success (v1.0)

- Boot kernel application successfully
- Run Elixir 1.17 hello world
- Pass tiered OTP test criteria
- No memory leaks in sanitizers
- Single binary deployment
- Realistic performance (5-8x BEAM JIT)

### 9.2 Nice-to-Have Success

- Performance better than 5x BEAM JIT
- Higher test pass rates
- Additional platform support
- Enhanced tooling

### 9.3 Failure Modes

**Project fails if**:
- Cannot boot kernel application
- Cannot pass basic OTP tests
- Memory leaks in core subsystems
- Cannot achieve single binary deployment
- Timeline exceeds 36 months

---

**Document Version**: 2.0
**Last Updated**: 2026-07-15
**Status**: Active
**Next Review**: 2026-08-15
**Target Completion**: January 2029
