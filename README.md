# SLATE

**A Fixed-Block Version Control System for TRG Files in SINC**

SLATE (**S**imple **L**ine-**A**ligned **T**ape **E**ngine) is a version control system engineered specifically for [TRG (Typed Relative Grid)](https://github.com/saptak7777/TRG) files. It operates on fixed 64-byte L1 cache-line blocks (1 block = 64 bytes = 64 TRG cells).

Written in pure bare-metal SINC, SLATE compiles to a standalone ~11 KB statically-linked Linux x86-64 ELF binary with zero libc dependencies and zero external runtime libraries.

---

## How Storage Works

SLATE stores repository data directly in the working directory using three binary files:

| File | Size / Geometry | Contents |
| :--- | :--- | :--- |
| **`state.slate`** | 256 Bytes (4 $\times$ 64B cache lines) | Line 0: Control header (8 native 64-bit QWORDs at 0x00..0x3F: magic `0x534C4154`, HEAD commit ID, commit count, arena block count, staged mask, shadow mask, tracked block count, merge parent).<br>Line 1: `Head_Map` (32 $\times$ 16-bit split-plane block IDs).<br>Line 2: `Stage_Map` (32 $\times$ 16-bit split-plane block IDs).<br>Line 3: `Shadow_Map` (32 $\times$ 16-bit split-plane block IDs). |
| **`manifest.slate`** | 128 Bytes per commit (2 $\times$ 64B cache lines) | Line 0: Commit descriptor (8 native 64-bit QWORDs at 0x00..0x3F: commit ID, parent A, parent B, block count, 64-bit tag word, changed block bitmask, reserved).<br>Line 1: `Commit_Map` (32 $\times$ 16-bit block IDs composing the snapshot). |
| **`arena.slate`** | 64 Bytes per block (append-only) | Immutable, deduplicated 64-byte content blocks. Physical byte offset of block $N$: $N \ll 6$. |

### Block Mapping & Diff Semantics
- **16-Bit Split-Plane Mapping**: Maps 32 logical file blocks to up to 65,536 physical arena blocks. Low bytes reside at offsets 0..31; high bytes reside at offsets 32..63.
- **1 Bit = 1 Byte**: In `diff` and `stat`, each 64-byte block produces a 64-bit mask where bit $b$ ($0 \le b < 64$) indicates whether byte $b$ (1 TRG cell) changed relative to HEAD.

---

## Build & Quickstart

```bash
# Build
./build.sh

# Optional: install to user PATH
cp bin/slate ~/.local/bin/

# Quickstart
slate init
slate track file.trg
slate update
slate shadow 1 patch.bin
slate accept file.trg

# Run test suite
./tests/test_harness.sh
```

---

## Command Reference

| Command | Arguments | Disk / Stdout Behavior | Exit Codes |
| :--- | :--- | :--- | :--- |
| `init` | none | Writes 256B `state.slate`, empty `manifest.slate`, empty `arena.slate`. | `0`: Success<br>`1`: Write error |
| `track` | `<file.trg>` | Reads file, appends unseen blocks to `arena.slate`, updates `Stage_Map` and staged bitmask in `state.slate`. | `0`: Success<br>`1`: File error or missing arg |
| `untrack` | none | Reverts `Stage_Map` to `Head_Map` and clears staged bitmask in `state.slate`. | `0`: Success<br>`1`: Clean (no changes staged) |
| `undo` | `<file.trg>` | Overwrites working file with blocks mapped in `Head_Map` from `arena.slate`. | `0`: Success<br>`1`: File error, missing arg, or no commits |
| `update` | none | Appends 128B commit record to `manifest.slate`, copies `Stage_Map` to `Head_Map`, clears staged mask. | `0`: Success<br>`1`: Nothing staged (`staged_mask == 0`) |
| `tag` | `<name>` | Writes 64-bit ASCII tag into current HEAD record in `manifest.slate`. | `0`: Success<br>`1`: Missing arg or no commits |
| `forget` | none | Rewinds HEAD in `state.slate` to Parent A. Staged mask retains popped changes. Allowed on Commit 0 (resets HEAD). | `0`: Success<br>`1`: Dirty tree, no commits, or tag is pinned (`0x70`) |
| `jump` | `<id> <file.trg>` | Rewinds or advances working file and HEAD in `state.slate` to commit `<id>`. | `0`: Success<br>`1`: Invalid ID or file error |
| `merge` | `<id>` | Bitwise 3-way merge of commit `<id>` into HEAD. Clean blocks staged; conflicting blocks placed in `Shadow_Map`. | `0`: Clean merge<br>`1`: Invalid ID<br>`2`: Conflicts staged to shadow |
| `shadow` | `<blk> <patch.bin>`| Appends 64B block to `arena.slate`, stages it into `Shadow_Map` at `<blk>`, sets bit in shadow mask. | `0`: Success<br>`1`: Invalid blk ($\ge 32$) or read error |
| `accept` | `<file.trg>` | Overlays `Shadow_Map` blocks onto working file and stages them in `Stage_Map`. Clears shadow mask. | `0`: Success<br>`1`: Missing arg or shadow mask is 0 |
| `reject` | none | Clears `Shadow_Map`, resets shadow mask, and clears merge parent pointer in `state.slate`. | `0`: Success<br>`1`: Shadow mask is 0 |
| `stat` | `<file.trg>` | Compares working file to HEAD. Writes an 8-byte binary word to stdout: `(changed_blocks << 32)` &#124; `changed_bytes`. | `0`: Success<br>`1`: File error or missing arg |
| `diff` | `<file.trg>` | Compares working file to HEAD. Writes `tracked_blocks * 8` bytes to stdout (one 64-bit mask per block, 1 bit = 1 byte). | `0`: Success<br>`1`: File error or missing arg |
| `history`| none | Streams all 128B commit records from `manifest.slate` directly to stdout in a single batch read. | `0`: Success |

