// src/main.zig - BEAM VM Main Entry Point
// Command-line interface for running BEAM files

const std = @import("std");
const beam_file = @import("beam_file.zig");
const vm = @import("vm.zig");
const executor = @import("executor.zig");
const term = @import("term.zig");
const control_flow = @import("control_flow.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <file.beam> [function] [arity]\n", .{args[0]});
        std.debug.print("Phase 2: Execute BEAM files with zvm\n", .{});
        return;
    }

    const filename = args[1];

    // Load BEAM file
    std.debug.print("Loading BEAM file: {s}\n", .{filename});
    var bf = try beam_file.parseBeamFile(allocator, filename);
    defer bf.deinit();

    std.debug.print("Loaded {d} atoms, {d} exports, {d} imports\n", .{
        bf.atoms.items.len,
        bf.exports.items.len,
        bf.imports.items.len,
    });

    // Initialize VM
    var virtual_machine = try vm.VM.init(allocator, bf);
    defer virtual_machine.deinit();

    // Get function to execute (default: add/2 for hello.beam)
    const function_name = if (args.len > 2) args[2] else "add";
    const function_arity = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 2;

    // Parse --args to set x registers
    // Find --args in arguments
    var arg_start: usize = 4; // Start after function arity
    var cli_args: [][:0]u8 = &[_][:0]u8{};
    while (arg_start < args.len) : (arg_start += 1) {
        if (std.mem.eql(u8, args[arg_start], "--args")) {
            // Found --args, collect remaining arguments
            cli_args = args[arg_start + 1 ..];
            break;
        }
    }

    // Set x registers from CLI arguments
    for (cli_args, 0..) |arg_str, i| {
        if (i >= virtual_machine.process.x_regs.len) break;
        // Try to parse as integer
        const int_val = std.fmt.parseInt(i64, arg_str, 10) catch |err| {
            std.debug.print("Warning: arg {s} is not a valid integer: {}\n", .{arg_str, err});
            continue;
        };
        virtual_machine.process.x_regs[i] = term.Term.makeSmallInt(int_val);
        std.debug.print("Set x{d} = {d}\n", .{i, int_val});
    }

    std.debug.print("\nExecuting function: {s}/{d}\n", .{ function_name, function_arity });

    // Find function in exports
    const func_info = virtual_machine.findFunction(function_name, function_arity) orelse {
        std.debug.print("Function {s}/{d} not found in exports\n", .{ function_name, function_arity });
        std.debug.print("Available exports:\n", .{});
        for (bf.exports.items) |exp| {
            std.debug.print("  {s}/{d}\n", .{ bf.getAtom(exp.function), exp.arity });
        }
        return;
    };

    std.debug.print("Found function: {s} (label {d})\n", .{ func_info.name, func_info.start_label });

    // Initialize executor
    var exec = executor.Executor.init(&virtual_machine);
    defer exec.deinit();

    // Set execution start position to function label
    try exec.setStartPosition(func_info.start_label);

    // Execute the program
    std.debug.print("\n=== Starting Execution ===\n", .{});
    try exec.execute();

    // Display result
    std.debug.print("\n=== Execution Result ===\n", .{});
    const result = virtual_machine.process.x_regs[0];
    if (result.isSmallInt()) {
        std.debug.print("Result: {d}\n", .{result.getSmallIntValue()});
    } else if (result.isAtom()) {
        std.debug.print("Result: atom({d})\n", .{result.getAtomIndex()});
    } else {
        std.debug.print("Result: raw term({x})\n", .{result.value});
    }
}