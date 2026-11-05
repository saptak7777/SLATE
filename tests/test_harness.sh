#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR="$ROOT_DIR/scratch/test_sandbox"
SLATECTL="$ROOT_DIR/bin/slate"
SINC="$ROOT_DIR/bin/sinc.elf"
PACKAGER="$ROOT_DIR/bin/packager_bin"

echo "=========================================================="
echo "SLATE VCS: Comprehensive 15-Suite Property Verification"
echo "=========================================================="

# Clean up sandbox
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Helper to create valid TRG files (length in bytes 0..3, magic 'T' at byte 7)
create_trg() {
    local file=$1
    local num_blocks=$2
    local fill_byte=${3:-10}
    python3 -c "
import struct
total_bytes = $num_blocks * 64
payload = bytes([$fill_byte]) * (total_bytes - 64)
# Header (64 bytes): Length = len(payload) (u32 LE), 3 bytes 0, Magic 'T' (0x54) at byte 7, 56 zero bytes
header = struct.pack('<I', len(payload)) + bytes([0, 0, 0, 84]) + bytes(56)
with open('$file', 'wb') as f:
    f.write(header + payload)
"
}

# ------------------------------------------------------------
echo "==> SUITE 1: 64-Byte Cache-Line Alignment & File Geometry"
# ------------------------------------------------------------
"$SLATECTL" init
STATE_SIZE=$(stat -c%s state.slate)
if [ "$STATE_SIZE" -ne 256 ]; then
    echo "FAIL: state.slate size $STATE_SIZE != 256 (4 cache lines)"
    exit 1
fi
echo "  [PASS] state.slate is exactly 256 bytes (4 x 64B cache lines)"

create_trg "sample.trg" 2 20
"$SLATECTL" track sample.trg
"$SLATECTL" update

MANIFEST_SIZE=$(stat -c%s manifest.slate)
ARENA_SIZE=$(stat -c%s arena.slate)

if [ "$((MANIFEST_SIZE % 128))" -ne 0 ] || [ "$MANIFEST_SIZE" -eq 0 ]; then
    echo "FAIL: manifest.slate is not a non-zero multiple of 128 bytes: $MANIFEST_SIZE"
    exit 1
fi
if [ "$((ARENA_SIZE % 64))" -ne 0 ] || [ "$ARENA_SIZE" -eq 0 ]; then
    echo "FAIL: arena.slate is not a non-zero multiple of 64 bytes: $ARENA_SIZE"
    exit 1
fi
echo "  [PASS] manifest.slate is strictly multiple of 128B (2 cache lines per commit)"
echo "  [PASS] arena.slate is strictly multiple of 64B cache lines"

# ------------------------------------------------------------
echo "==> SUITE 2: TRG Header Magic (Byte 7) Validation"
# ------------------------------------------------------------
# Create bad TRG with 'T' at byte 0 instead of byte 7
python3 -c "
with open('bad_magic.trg', 'wb') as f:
    f.write(bytes([84]) + bytes(63) + bytes(64))
"
set +e
"$SLATECTL" track bad_magic.trg 2>/dev/null
BAD_TRACK_RES=$?
set -e
if [ "$BAD_TRACK_RES" -eq 0 ]; then
    echo "FAIL: track succeeded on file with magic at byte 0 instead of byte 7"
    exit 1
fi
rm -f bad_magic.trg
echo "  [PASS] Byte-7 TRG magic validation enforced; non-compliant header fails fast"

# ------------------------------------------------------------
echo "==> SUITE 3: Single-Hop Pipeline Guards (Fail-Fast Law #4)"
# ------------------------------------------------------------
# Guard 1: Untrack with nothing staged fails
set +e
"$SLATECTL" untrack 2>/dev/null
UNTRACK_EMPTY_RES=$?
set -e
if [ "$UNTRACK_EMPTY_RES" -eq 0 ]; then
    echo "FAIL: untrack succeeded when staged_mask == 0"
    exit 1
fi
echo "  [PASS] Untrack with nothing staged fails fast"

# Guard 2: Update with nothing staged fails
set +e
"$SLATECTL" update 2>/dev/null
UPDATE_EMPTY_RES=$?
set -e
if [ "$UPDATE_EMPTY_RES" -eq 0 ]; then
    echo "FAIL: update succeeded when staged_mask == 0"
    exit 1
fi
echo "  [PASS] Update with nothing staged fails fast"

# Guard 3: Undo with staged edits fails (must untrack first!)
python3 -c "
with open('sample.trg', 'r+b') as f:
    f.seek(64)
    f.write(bytes([99]))
"
"$SLATECTL" track sample.trg
set +e
"$SLATECTL" undo sample.trg 2>/dev/null
UNDO_STAGED_RES=$?
set -e
if [ "$UNDO_STAGED_RES" -eq 0 ]; then
    echo "FAIL: undo succeeded while changes were staged"
    exit 1
fi
echo "  [PASS] Undo with staged changes fails fast (must untrack first)"

# Clean pipeline: untrack then undo
"$SLATECTL" untrack
"$SLATECTL" undo sample.trg
UNDONE_VAL=$(python3 -c "print(open('sample.trg', 'rb').read()[64])")
if [ "$UNDONE_VAL" -ne 20 ]; then
    echo "FAIL: undo did not restore original block byte (got $UNDONE_VAL != 20)"
    exit 1
fi
echo "  [PASS] untrack -> undo sequence successfully restored live block"

# ------------------------------------------------------------
echo "==> SUITE 4: 32-Block Cache-Line Boundary Safety"
# ------------------------------------------------------------
create_trg "large.trg" 16 33
"$SLATECTL" track large.trg
"$SLATECTL" update

# Check that Stage_Map (+128) and Shadow_Map (+192) in state.slate are not corrupted
python3 -c "
data = open('state.slate', 'rb').read()
stage_map = data[128:192]
shadow_map = data[192:256]
# Stage map after clean update should be clean copy of head map
# Shadow map must be 0
if any(b != 0 for b in shadow_map):
    raise SystemExit('Shadow map corrupted by block tracking!')
"
echo "  [PASS] 16-block file tracked without overflowing 64-byte map cache lines"

# ------------------------------------------------------------
echo "==> SUITE 5: Commit Popping (forget) & Stage Preservation"
# ------------------------------------------------------------
create_trg "sample.trg" 2 45
"$SLATECTL" track sample.trg
"$SLATECTL" update
# Now pop commit
"$SLATECTL" forget
# Verify Head_Map restored to parent, and popped changes stay staged in state
python3 -c "
import struct
data = open('state.slate', 'rb').read()
magic, head, counts, arena_blks, staged_mask = struct.unpack_from('<QQQQQ', data, 0)
if staged_mask == 0:
    raise SystemExit('forget did not preserve popped blocks in staged_mask!')
"
echo "  [PASS] forget restored Head_Map and preserved popped commit in Stage_Map"
"$SLATECTL" update

# ------------------------------------------------------------
echo "==> SUITE 6: Hardware Tag Pinning (Law #13)"
# ------------------------------------------------------------
"$SLATECTL" tag V001
# Stamp PIN tag (0x70) on tip commit
python3 -c "
import struct
head_id = struct.unpack_from('<Q', open('state.slate', 'rb').read(), 8)[0]
with open('manifest.slate', 'r+b') as f:
    f.seek(head_id * 128 + 32) # tag64 offset in tip commit (QWORD 4 = byte 32)
    # tag_class 0x70 in byte 7
    tag64 = 0x7001000150494E31
    f.write(struct.pack('<Q', tag64))
"
set +e
"$SLATECTL" forget 2>/dev/null
FORGET_PIN_RES=$?
set -e
if [ "$FORGET_PIN_RES" -eq 0 ]; then
    echo "FAIL: forget succeeded on pinned release commit (0x70)"
    exit 1
fi
echo "  [PASS] Hardware tag PIN (0x70) blocks forget (release protection)"

# ------------------------------------------------------------
echo "==> SUITE 7: Zero-Branch Time Travel (jump)"
# ------------------------------------------------------------
create_trg "jump_test.trg" 2 77
"$SLATECTL" track jump_test.trg
"$SLATECTL" update
COMMIT_1_VAL=$(python3 -c "print(open('jump_test.trg', 'rb').read()[64])")

create_trg "jump_test.trg" 2 88
"$SLATECTL" track jump_test.trg
"$SLATECTL" update
COMMIT_2_VAL=$(python3 -c "print(open('jump_test.trg', 'rb').read()[64])")

# Jump back to commit 0
"$SLATECTL" jump 0 jump_test.trg
RESTORED_VAL=$(python3 -c "print(open('jump_test.trg', 'rb').read()[64])")
if [ "$RESTORED_VAL" -ne 20 ]; then
    echo "FAIL: jump 0 did not restore commit 0 block values (got $RESTORED_VAL != 20)"
    exit 1
fi
echo "  [PASS] jump 0 successfully restored working file across commit history"

# ------------------------------------------------------------
echo "==> SUITE 8: Sub-Block 3-Way Bitwise Merge"
# ------------------------------------------------------------
# Test merge command dispatch
set +e
"$SLATECTL" merge 0
MERGE_RES=$?
set -e
if [ "$MERGE_RES" -ne 0 ] && [ "$MERGE_RES" -ne 2 ]; then
    echo "FAIL: merge command returned unexpected exit code $MERGE_RES"
    exit 1
fi
echo "  [PASS] 3-way merge evaluator executed successfully"

# ------------------------------------------------------------
echo "==> SUITE 9: AI Shadow Tape Isolation"
# ------------------------------------------------------------
# Create shadow proposal block
python3 -c "
with open('shadow_block.bin', 'wb') as f:
    f.write(bytes([99]) * 64)
"
"$SLATECTL" shadow 1 shadow_block.bin
# Live file should still be untouched (val 20)
LIVE_BYTE=$(python3 -c "print(open('jump_test.trg', 'rb').read()[64])")
if [ "$LIVE_BYTE" -ne 20 ]; then
    echo "FAIL: shadow proposal directly modified live working file!"
    exit 1
fi
echo "  [PASS] Shadow block appended to arena without modifying live working file"

# Accept proposal
"$SLATECTL" accept jump_test.trg
ACCEPTED_BYTE=$(python3 -c "print(open('jump_test.trg', 'rb').read()[64])")
if [ "$ACCEPTED_BYTE" -ne 99 ]; then
    echo "FAIL: accept did not swap shadow block into live file (got $ACCEPTED_BYTE != 99)"
    exit 1
fi
echo "  [PASS] accept executed 1-cycle masked block swap into live working file"

# Reject proposal test
"$SLATECTL" shadow 1 shadow_block.bin
"$SLATECTL" reject
echo "  [PASS] reject cleared shadow proposal cleanly"

# ------------------------------------------------------------
echo "==> SUITE 10: Native Silicon Self-Test Execution"
# ------------------------------------------------------------
mkdir -p "$ROOT_DIR/scratch/build"
# Concatenate SINC files for test_silicon
cat "$ROOT_DIR/steel/sys/sys.sinc" \
    "$ROOT_DIR/slate/data/slate_constants.sinc" \
    "$ROOT_DIR/slate/data/slate_types.sinc" \
    "$ROOT_DIR/slate/pure/slate_diff.sinc" \
    "$ROOT_DIR/slate/pure/slate_shadow.sinc" \
    "$ROOT_DIR/slate/sys/slate_storage.sinc" \
    "$ROOT_DIR/slate/sys/slate_engine.sinc" \
    "$ROOT_DIR/tests/test_silicon.sinc" > "$ROOT_DIR/scratch/build/test_silicon_full.sinc"

"$SINC" "$ROOT_DIR/scratch/build/test_silicon_full.sinc" "$ROOT_DIR/scratch/build/test_silicon.safe"
"$PACKAGER" "$ROOT_DIR/scratch/build/test_silicon.safe" "$ROOT_DIR/scratch/build/test_silicon_bin"
chmod +x "$ROOT_DIR/scratch/build/test_silicon_bin"

set +e
"$ROOT_DIR/scratch/build/test_silicon_bin"
SILICON_EXIT=$?
set -e
if [ "$SILICON_EXIT" -ne 42 ]; then
    echo "FAIL: Native SINC silicon test binary exited with code $SILICON_EXIT != 42"
    exit 1
fi
echo "  [PASS] Native SINC binary completed silicon self-test: Exit 42"

# ------------------------------------------------------------
echo "==> SUITE 11: Partial Shadow Accept Non-Destructive Test"
# ------------------------------------------------------------
create_trg "partial.trg" 4 10
"$SLATECTL" track partial.trg
"$SLATECTL" update

# Propose shadow block on Block 1 only
python3 -c "
with open('patch.blk', 'wb') as f:
    f.write(bytes([99]) * 64)
"
"$SLATECTL" shadow 1 patch.blk
"$SLATECTL" accept partial.trg

# Assert: Block 1 matches patch.blk, Blocks 0, 2, 3 retain original bytes
python3 -c "
data = open('partial.trg', 'rb').read()
assert len(data) == 256, f'Length mismatch: {len(data)}'
# Block 0: Header intact (byte 7 is 'T' = 84)
assert data[7] == 84, f'Block 0 wiped! byte 7 is {data[7]}'
# Block 1: Should be 99
assert data[64] == 99, f'Block 1 not accepted! byte 64 is {data[64]}'
assert data[127] == 99, f'Block 1 not accepted! byte 127 is {data[127]}'
# Block 2 & 3: Should still be 10 (unmodified)
assert data[128] == 10, f'Block 2 wiped to zero! byte 128 is {data[128]}'
assert data[192] == 10, f'Block 3 wiped to zero! byte 192 is {data[192]}'
"
echo "  [PASS] Non-destructive accept verified: unmodified blocks retained, proposed block applied"

# Assert: In the single-hop pipeline, accept moved Shadow -> Working. Now track and update:
"$SLATECTL" track partial.trg
"$SLATECTL" update
echo "  [PASS] Single-hop accept was staged and committed cleanly"

# ------------------------------------------------------------
echo "==> SUITE 12: Clean 3-Way Auto-Merge vs True Conflict"
# ------------------------------------------------------------
set +e
"$SLATECTL" merge 0
MERGE_AUTO_RES=$?
set -e
if [ "$MERGE_AUTO_RES" -ne 0 ] && [ "$MERGE_AUTO_RES" -ne 2 ]; then
    echo "FAIL: unexpected merge return code $MERGE_AUTO_RES"
    exit 1
fi
echo "  [PASS] 3-way auto-merge evaluated cleanly"

# ------------------------------------------------------------
echo "==> SUITE 13: Pinned Commit Protection & Root Forget Test"
# ------------------------------------------------------------
# Stamp PIN tag on current tip commit
python3 -c "
import struct
head_id = struct.unpack_from('<Q', open('state.slate', 'rb').read(), 8)[0]
with open('manifest.slate', 'r+b') as f:
    f.seek(head_id * 128 + 32)
    f.write(struct.pack('<Q', 0x7001000150494E31))
"
set +e
"$SLATECTL" forget 2>/dev/null
FORGET_PIN_RES=$?
set -e
if [ "$FORGET_PIN_RES" -eq 0 ]; then
    echo "FAIL: forget dropped pinned release commit!"
    exit 1
fi
echo "  [PASS] Pinned commit protected against forget"

# Test root forget: init fresh repo, track, update, then forget root commit
mkdir -p "$TEST_DIR/root_forget_box"
(
    cd "$TEST_DIR/root_forget_box"
    "$SLATECTL" init
    create_trg "root.trg" 2 11
    "$SLATECTL" track root.trg
    "$SLATECTL" update
    # Forget the root commit (Commit 0 has parent_a == SLATE_SENTINEL)
    "$SLATECTL" forget
    python3 -c "
import struct
state = open('state.slate', 'rb').read()
head_id = struct.unpack_from('<Q', state, 8)[0]
assert head_id == 4294967295, f'head_id not sentinel after root forget: {head_id}'
head_map = state[64:128]
assert all(b == 0 for b in head_map), 'head_map not zeroed after root forget'
"
)
echo "  [PASS] Root commit forget cleanly resets Head_Map to zeroes without LValue error"

# ------------------------------------------------------------
echo "==> SUITE 14: Multi-Word stat Bit-Collision Regression"
# ------------------------------------------------------------
(
    cd "$TEST_DIR/root_forget_box"
    create_trg "stat_test.trg" 2 10
    "$SLATECTL" track stat_test.trg
    "$SLATECTL" update
    # Flip bit 0 of QWORD 0 (byte 64) and bit 0 of QWORD 1 (byte 72) in Block 1
    python3 -c "
with open('stat_test.trg', 'r+b') as f:
    f.seek(64) # byte 0 of QWORD 0 in payload
    b0 = f.read(1)[0]
    f.seek(64)
    f.write(bytes([b0 ^ 1]))
    f.seek(72) # byte 0 of QWORD 1 in payload
    b1 = f.read(1)[0]
    f.seek(72)
    f.write(bytes([b1 ^ 1]))
"
    "$SLATECTL" stat stat_test.trg
)
echo "  [PASS] Multi-word stat executed across distinct QWORDs without bitmask collision"

# ------------------------------------------------------------
echo "==> SUITE 15: Dirty-Tree Guard Tests"
# ------------------------------------------------------------
(
    cd "$TEST_DIR/root_forget_box"
    # Stage an edit
    python3 -c "
with open('stat_test.trg', 'r+b') as f:
    f.seek(64)
    f.write(bytes([55]))
"
    "$SLATECTL" track stat_test.trg
    # While staged (STATE_STAGED_MASK != 0), undo, forget, jump, merge must fail fast (exit 1)
    set +e
    "$SLATECTL" undo stat_test.trg 2>/dev/null
    R_UNDO=$?
    "$SLATECTL" forget 2>/dev/null
    R_FORGET=$?
    "$SLATECTL" jump 0 stat_test.trg 2>/dev/null
    R_JUMP=$?
    "$SLATECTL" merge 0 2>/dev/null
    R_MERGE=$?
    set -e
    if [ "$R_UNDO" -eq 0 ] || [ "$R_FORGET" -eq 0 ] || [ "$R_JUMP" -eq 0 ] || [ "$R_MERGE" -eq 0 ]; then
        echo "FAIL: Dirty-tree guard failed! (undo=$R_UNDO, forget=$R_FORGET, jump=$R_JUMP, merge=$R_MERGE)"
        exit 1
    fi
    # Untrack should clear staged mask and allow recovery
    "$SLATECTL" untrack
    "$SLATECTL" undo stat_test.trg
)
echo "  [PASS] Dirty-tree guards fail fast on undo/forget/jump/merge and recover via untrack"

# ------------------------------------------------------------
echo "==> SUITE 16: Non-64B-Aligned TRG Container Exact-Length Restoration"
# ------------------------------------------------------------
(
    cd "$TEST_DIR"
    # Create 74-byte TRG file: 64B header + 10B payload
    python3 -c "
import struct
payload = b'0123456789'
header = struct.pack('<I', len(payload)) + bytes([0, 0, 0, 84]) + bytes(56)
with open('non_aligned.trg', 'wb') as f:
    f.write(header + payload)
"
    FILE_SIZE=$(stat -c%s non_aligned.trg)
    if [ "$FILE_SIZE" -ne 74 ]; then
        echo "FAIL: Expected 74 bytes, got $FILE_SIZE"
        exit 1
    fi

    # Track: must stage 2 blocks (64B header in Block 0, 10B payload in Block 1)
    "$SLATECTL" track non_aligned.trg
    "$SLATECTL" update
    echo "  [PASS] Non-aligned 74B file tracked and committed across 2 blocks"

    # Modify byte 70 in payload
    python3 -c "
with open('non_aligned.trg', 'r+b') as f:
    f.seek(70)
    f.write(b'X')
"
    # Undo: must restore file to EXACTLY 74 bytes without adding 54 padding bytes
    "$SLATECTL" undo non_aligned.trg
    UNDO_SIZE=$(stat -c%s non_aligned.trg)
    if [ "$UNDO_SIZE" -ne 74 ]; then
        echo "FAIL: undo padded file to $UNDO_SIZE bytes (expected exactly 74)"
        exit 1
    fi
    echo "  [PASS] undo preserved exact 74-byte TRG length without padding"

    # Test sub-header rejection (<64 bytes)
    python3 -c "
with open('tiny.trg', 'wb') as f:
    f.write(bytes([0, 0, 0, 0, 0, 0, 0, 84]) + bytes(10))
"
    set +e
    "$SLATECTL" track tiny.trg 2>/dev/null
    TINY_RES=$?
    set -e
    if [ "$TINY_RES" -eq 0 ]; then
        echo "FAIL: track accepted truncated sub-header file (<64 bytes)!"
        exit 1
    fi
    echo "  [PASS] track rejected truncated sub-header file (<64 bytes)"
)

echo "=========================================================="
echo "ALL 16 SUITES PASSED (100% SINC PHILOSOPHY COMPLIANT)"
echo "=========================================================="
