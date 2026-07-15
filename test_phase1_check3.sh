#!/bin/bash
# Phase 1 Check 3: Test disassembler on multiple BEAM files

echo "=== Phase 1 Check 3: Multi-BEAM File Test ==="
echo ""

# Array of BEAM files to test
BEAM_FILES=("hello.beam" "test_simple.beam" "test_records.beam" "test_complex.beam")

# Test results tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

for beam_file in "${BEAM_FILES[@]}"; do
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "Testing: $beam_file"

    # Run disassembler and capture output
    if ./zig-out/bin/zvm-disasm "$beam_file" > /dev/null 2>&1; then
        echo "  ✅ PASSED - Successfully parsed $beam_file"
        PASSED_TESTS=$((PASSED_TESTS + 1))

        # Show some details
        atom_count=$(./zig-out/bin/zvm-disasm "$beam_file" | grep "Atoms:" | awk '{print $2}')
        export_count=$(./zig-out/bin/zvm-disasm "$beam_file" | grep "Exports:" | awk '{print $2}')
        import_count=$(./zig-out/bin/zvm-disasm "$beam_file" | grep "Imports:" | awk '{print $2}')
        echo "    - Atoms: $atom_count, Exports: $export_count, Imports: $import_count"
    else
        echo "  ❌ FAILED - Error parsing $beam_file"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    echo ""
done

echo "=== Test Summary ==="
echo "Total Tests: $TOTAL_TESTS"
echo "Passed: $PASSED_TESTS"
echo "Failed: $FAILED_TESTS"
echo ""

if [ $PASSED_TESTS -eq $TOTAL_TESTS ]; then
    echo "✅ Phase 1 Check 3: PASSED"
    exit 0
else
    echo "❌ Phase 1 Check 3: FAILED"
    exit 1
fi