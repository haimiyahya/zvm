# zvm

**Zig BEAM Virtual Machine** - A fully featured BEAM virtual machine implementation written in Zig, capable of loading and executing bytecode compiled by the real Erlang compiler.

## Project Vision

zvm aims to be a 100% compatible, drop-in replacement for the Erlang BEAM VM, written entirely in Zig. The goal is a single, minimal binary that contains everything needed to run Erlang bytecode with identical semantics to the official BEAM VM.

### Key Objectives

- **BEAM Compatibility**: Load and execute real Erlang-compiled bytecode without modification
- **Single Binary**: All functionality in one self-contained executable
- **Minimal Footprint**: Optimized for size and resource efficiency
- **Realistic Performance**: 5-8x BEAM JIT for interpreter-only v1.0
- **Zig Benefits**: Memory safety, modern tooling, and cross-platform support

## Current Status

**Phase**: Early Development | **BEAM Compatibility**: 0% | **Status**: Research & Design

The project is in initial research and design phase. Core infrastructure exists but BEAM implementation has not begun.

**Timeline**: 30 months for 95% OTP compatibility (target: January 2029)

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│         Erlang/Elixir Applications          │
├─────────────────────────────────────────────┤
│              .beam files                    │
├─────────────────────────────────────────────┤
│            zvm (Zig BEAM VM)               │
│  ┌──────────────────────────────────────┐  │
│  │  Process Management & SMP Scheduler  │  │
│  │  Memory Management & GC              │  │
│  │  Pattern Matching Engine             │  │
│  │  BIFs Implementation (~1600 funcs)   │  │
│  │  Code Loading & Hot Code Swap       │  │
│  │  ETS & Persistent Terms             │  │
│  │  Exception Handling & Supervision   │  │
│  │  Distribution (v1.2)                │  │
│  └──────────────────────────────────────┘  │
├─────────────────────────────────────────────┤
│              Zig Runtime                    │
├─────────────────────────────────────────────┤
│               Operating System              │
└─────────────────────────────────────────────┘
```

## Quick Start

```bash
# Build the project
zig build

# Run a .beam file (future)
./zig-out/bin/zvm my_module.beam

# Run tests
zig build test
```

## Requirements

- Zig >= 0.14.0
- Erlang/OTP compiler (for testing compatibility)
- Linux (primary target: ARM aarch64)

## Documentation

For detailed project documentation:

- [ARCHITECTURE.md](docs/ARCHITECTURE.md) - Technical architecture and design
- [PROJECT_SCOPE.md](docs/PROJECT_SCOPE.md) - Detailed project scope and critical subsystems
- [MILESTONES.md](docs/MILESTONES.md) - Development phases and 30-month roadmap
- [SUCCESS_CRITERIA.md](docs/SUCCESS_CRITERIA.md) - Success metrics and tiered compatibility criteria

## Project Scope

### Critical Subsystems Required for BEAM Compatibility

**v1.0 Must Include**:
- Process management with SMP scheduler (~2KB per process)
- Stack/heap co-location memory model
- Generational garbage collection
- Binary handling (Refc, ProcBinary, SubBinary)
- ETS (set, bag, duplicate_bag, ordered_set)
- Hot code loading (core for OTP)
- ~1600 BIFs (implemented in tiers)
- Exception handling and stacktraces
- Link/monitor system signals
- Time subsystem and timers

### Explicit v1.0 Non-Goals

The following are explicitly **out of scope for v1.0**:
- ❌ Distribution and clustering (v1.2+)
- ❌ JIT compilation (interpreter-only)
- ❌ Full NIF support (stub only)
- ❌ HiPE native code (deprecated in OTP)
- ❌ Advanced profiling and tracing

## Roadmap

See [MILESTONES.md](docs/MILESTONES.md) for detailed 8-phase development roadmap:

- **Phase 1** (Months 1-3): Foundations - Term representation, BEAM loader, disassembler
- **Phase 2** (Months 4-6): Interpreter Core - Single scheduler, core opcodes
- **Phase 3** (Months 7-10): Memory Management - GC, binaries, stack/heap co-location
- **Phase 4** (Months 11-14): BIFs Tier 1 - Core language, exceptions, trap/yield protocol
- **Phase 5** (Months 15-18): Concurrency - SMP scheduler, messaging, system signals
- **Phase 6** (Months 19-22): ETS & System - ETS, code server, application boot
- **Phase 7** (Months 23-27): Full Compatibility - Remaining BIFs, full boot, hot loading
- **Phase 8** (Months 28-30): Hardening - Optimization, stability, production readiness

**Total Duration**: 30 months for 95% OTP compatibility

## Success Criteria

### Tiered OTP Compatibility

**Critical Success Metric**: Tiered test suite pass rates

| Test Suite | Target | Status |
|------------|--------|--------|
| Emulator Suite | >= 98% | ⏳ 0% |
| Stdlib Suite | >= 95% | ⏳ 0% |
| Kernel Suite | >= 90% | ⏳ 0% |
| Compiler Suite | >= 90% | ⏳ 0% |

### Performance Targets

**v1.0** (Phase 8): 5-8x BEAM JIT performance (realistic for interpreter-only)
- Process creation: < 1μs
- Message passing: < 100ns latency
- Idle process memory: < 4KB
- Boot to kernel: < 200ms

### v1.0 Success Definition

- Can boot `init`, `erl_prim_loader`, `prim_eval`
- Can run Elixir 1.17 hello world
- Can run simple mix projects
- Tiered OTP test criteria met
- No memory leaks in sanitizers
- Single binary < 10MB

## Technical Highlights

### Architecture Philosophy

- **Single scheduler before SMP**: Correctness before complexity
- **Stack/heap co-location**: Critical for correct GC implementation
- **Trap/yield protocol**: All BIFs support trapping for long operations
- **Reference counting**: Complex binary subsystem with Refc/ProcBinary

### Implementation Strategy

1. **Phase 1**: Term representation, BEAM loader, disassembler
2. **Phase 2**: Single scheduler, core opcodes, basic PCB
3. **Phase 3**: Memory management (stack+heap co-location), GC, binaries
4. **Phase 4**: BIFs, exceptions, trap/yield protocol
5. **Phase 5**: SMP scheduler, concurrency, messaging
6. **Phase 6**: ETS, persistent terms, code server
7. **Phase 7**: Remaining BIFs, full boot, hot loading
8. **Phase 8**: Optimization, hardening, production readiness

### Key Risks

**High Risk Areas**:
- Binary handling and GC interaction (hardest memory subsystem)
- Exception semantics and stacktraces (complex edge cases)
- Boot sequence (undocumented magic)
- BIF trap and yield protocol (must be designed from start)

## Contributing

This is a complex systems programming project. Contributions welcome in areas such as:

- BEAM instruction implementation
- Memory management research
- Testing and compatibility verification
- Performance optimization
- Documentation and examples

**Development Approach**:
- Ask first, implement second (consult BEAM experts when unsure)
- Test against real BEAM behavior before declaring compatibility
- Use sanitizers extensively (valgrind, ASAN) for memory safety
- Incremental development with strict phase boundaries

## References

- [The BEAM Book](https://beam-book.org) - Comprehensive BEAM documentation
- [BEAM Instruction Set](https://github.com/erlang/otp/blob/master/lib/compiler/src/beam_asm.erl)
- [Erlang Runtime System](https://erlang.org/doc/man/erl.html)
- [OTP Internal Docs](erts/emulator/internal_doc)

## License

TBD

---

**Project Status**: Early Development | **Timeline**: 30 months | **Target**: January 2029
**Last Updated**: 2026-07-15 | **Next Milestone**: Phase 1 - Foundations
