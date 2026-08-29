# nivi

A high-performance text buffer (rope) written in Zig, intended to be the core
data structure of a fast terminal editor.

The rope stores raw bytes, keeps `O(log n)` byte/line metrics on every branch,
uses slab allocation for cache-dense nodes, and offers an editor-oriented API
(cursor-local editing, viewport range copy, UTF-8 safety, and a fast Unicode
layout layer).

## Layout

- `src/rope.zig` — the `Rope` data structure, all edit/query APIs, and tests.
- `src/buffer.zig` — headless editor core: `Buffer`, `Cursor`, `Selection`.
- `src/undotree.zig` — persistent undo/redo tree (`UndoTree`).
- `src/render.zig` — terminal render pipeline primitives: surface grid,
  styles, rects, view tree, frame diffing, and viewport rendering.
- `src/input.zig` — terminal key / escape-sequence decoder.
- `src/terminal.zig` — raw-mode and alternate-screen terminal lifecycle helpers.
- `src/bench_rope.zig` — rope + buffer benchmark harness (`zig build bench`).
- `src/bench_undotree.zig` — undo-tree benchmark harness (`zig build bench-undo`).
- `src/bench_render.zig` — render/input/load/save benchmark harness (`zig build bench-render`).
- `src/root.zig` — public module entry (re-exports + forces test discovery).
- `src/main.zig` — full-screen terminal editor entry with line-command fallback.

## Build / test / bench

```sh
zig build test
zig build bench -Doptimize=ReleaseFast
zig build bench-undo -Doptimize=ReleaseFast
zig build bench-render -Doptimize=ReleaseFast
```

## Current CLI

```sh
zig build run -- path/to/file.txt
zig build run -- --line path/to/file.txt
```

Default mode enters the alternate screen, enables raw mode, detects the terminal
size, renders an editor viewport with relative line numbers + statusline +
Vim-style command bar, and uses incremental ANSI frame diffing. Normal-mode keys:
`h/j/k/l`, arrows, `0`, `$`, `x`, `u`, `r`, `i`, and `:`. Insert mode exits with
`Esc`. Command bar supports `:w`, `:q`, `:q!`, `:wq`, and `:x`. Use `--line` for
the scriptable line-command fallback. Cursor shape follows Vim convention: block
cursor in normal/command mode, bar cursor in insert mode.

## Architecture

- **Nodes**: `union(enum) { branch, leaf }`, slab-allocated (`4096` nodes/slab).
- **Branch**: caches `weight` (left byte len), `line_count` (left newlines),
  `byte_len` (subtree bytes), `total_line_count` (subtree newlines), `height`.
- **Leaf**: `data: *LeafData` + `len` + `line_count`. Payload (`text` +
  `newline_bits`) lives in a **separate leaf-data slab** so branch nodes stay
  small and cache-dense (`node_size = 64`).
- **Leaf capacity**: `160` bytes (tuned by benchmarking `64/96/128/160/192/256`).
- **Newline index**: each leaf keeps a `u64` bitset of newline positions for
  `O(popcount)` in-leaf line lookup.
- **Balancing**: AVL-style rotations on `concat`; edge inserts mutate branches
  in place when balanced; in-leaf edits mutate leaf bytes directly.

## Benchmark snapshot (ReleaseFast, native, best-of-5)

Representative numbers on the development machine (relative comparison matters
more than absolute values):

| Benchmark | ns/op | Notes |
|---|---|---|
| `build_1mib` | ~1.4M | full construct of 1 MiB |
| `build_10mib` | ~16M | full construct of 10 MiB |
| `byte_at_200k` | ~100 | random byte lookup |
| `line_column_100k` | ~240 | line/column → byte offset |
| `viewport_10k_x50` | ~470 | copy 50-line viewport range |
| `many_lines_lookup_100k` | ~200 | 250k tiny lines |
| `huge_lines_byte_at_200k` | ~110 | single 4 MiB line |
| `insert_20k` | ~2.1K | random inserts into 1 MiB |
| `delete_10k` | ~500 | random deletes |
| `random_edit_20k` | ~1.4K | mixed random edits |
| `cursor_type_100k` | ~14 | cursor-local sequential typing |
| `buffer_type_100k` | ~14 | `Buffer.Cursor.insertText` (fast path) |
| `buffer_backspace_50k` | ~90 | `Buffer.Cursor.deleteBackward` |
| `normal_type_100k` | ~30 | append typing via root |
| `utf8_type_100k` | ~32 | boundary-checked typing |
| `flatten` | ~700K | flatten 1 MiB to a slice |
| `utf8_validate_1mib` | ~3.3M | streaming UTF-8 validation |
| `utf8_count_1mib` | ~3.4M | streaming codepoint count |
| `grapheme_count_1mib` | ~21M | streaming grapheme count |
| `display_width_1mib` | ~21M | streaming display width |
| `visual_column_100k` | ~630 | visual column → byte (line fast path) |

## Done

### Core rope
- [x] Tagged-union branch/leaf nodes with slab allocation.
- [x] Cached branch metrics (`byte_len`, `line_count`, `total_line_count`, `height`).
- [x] Separate leaf-data slab pool (compact 64-byte branch nodes).
- [x] Balanced construction (`setText`) with direct branch creation.
- [x] AVL-style `concat` with leaf coalescing.
- [x] Split with boundary reuse (no alloc at exact node/leaf boundaries).
- [x] `insert` / `delete` with in-leaf mutation fast path.
- [x] Mutable in-place append/prepend at buffer edges.
- [x] Empty-leaf pruning; root cleared on full delete.
- [x] Explicit `compact()` (flatten + rebuild + release old slabs).
- [x] `setText` releases previous slabs.

### Editor API
- [x] `byteAt`, `byteLen`, `lineCount`.
- [x] `byteOffsetForLine`, `byteOffsetForLineColumn` (byte column).
- [x] `byteRangeForLines` (viewport).
- [x] `copyRange` (range copy without full flatten).
- [x] `toOwnedSlice` (flatten).
- [x] `Cursor` + `seekCursor` + `insertAtCursor` (cursor-local editing).
- [x] `Stats` diagnostics + `validate()` invariant checker.

### Unicode
- [x] Per-leaf newline `u64` bitset index.
- [x] `isUtf8Boundary`, `prevUtf8Boundary`, `nextUtf8Boundary`, `resolveUtf8Boundary`.
- [x] `codepointAt`, `codepoints` iterator.
- [x] Streaming `validateUtf8`, `countCodepointsUtf8` (leaf-slice, ASCII fast path).
- [x] `insertUtf8` / `deleteUtf8` with `BoundaryMode` (assert / clamp back / clamp forward).
- [x] Grapheme iteration (`graphemes`, `countGraphemes`) — heuristic segmentation.
- [x] Display width (`displayWidth`) + `byteOffsetForLineVisualColumn` (tab-aware).
- [x] Honest `nfcStatus` / `UnicodeSupport` capability descriptor.

### Testing / tooling
- [x] Correctness tests incl. UTF-8, cross-leaf codepoints, boundaries,
      deterministic random-edit model check vs `ArrayList`.
- [x] `validate()` woven into heavy edit tests.
- [x] Best-of-N benchmark harness covering build/lookup/edit/typing/viewport/Unicode.
- [x] `root.zig` forces test discovery for all modules (`test { _ = @import(...) }`).

### Editor core (headless)
- [x] `Buffer`: wraps `Rope`, edit-generation counter, dirty flag, tab width,
      line-ending policy; line metrics, `lineContentRange`, `visualColumnAt`.
- [x] `Rope.lineAt` (offset → line index) via branch line counts + leaf popcount.
- [x] `Rope.nextGraphemeBoundary` / `prevGraphemeBoundary` (cluster movement)
      with ASCII fast paths + bounded-window scan (no per-byte tree descents).
- [x] `Rope.deleteAtCursor` / `deleteBeforeCursor` (cursor-local delete/backspace).
- [x] `Cursor`: generation-stamped, grapheme-aware left/right/line-start/line-end,
      vertical move with sticky goal column, `sync()` re-validation after edits.
- [x] `Cursor` typing fast path: drives an internal `Rope.Cursor`, so
      `insertText` / `deleteBackward` / `deleteForward` mutate the cached leaf in
      place; auto re-seeds (lazy) after movement or external edits.
- [x] `Selection`: anchor/head range, `deleteFrom`, generation-safe `sync()`.

### Rendering pipeline
- [x] `Surface`: reusable terminal cell grid with clipped writes and buffered
      flush to an output writer.
- [x] `Rect` + viewport rendering entry point (`renderBufferViewport`) so future
      components can render into isolated regions.
- [x] `ViewTree`: component region registry for editor, sidebars, statusline,
      and telescope-style picker overlays.
- [x] `AnsiRenderer`: full repaint + changed-cell diff renderer, plus
      `renderDiffRects` for dirty-region-only output.
- [x] `FrameRenderer`: double-buffered current/previous surfaces with automatic
      first-frame full render, dirty-rect diff, and full-screen diff fallback.
- [x] Line-number gutter as the first composable side component.
- [x] Relative line numbers with highlighted absolute cursor line.
- [x] Vertical and horizontal scrolling: the viewport follows the cursor by
      line (`first_line`) and visual column (`first_column`), so long lines scroll
      sideways instead of clamping the caret.
- [x] Viewport rendering copies only visible line ranges from the rope, avoiding
      whole-buffer flattening; long lines clipped to a visible-byte budget.
- [x] Reusable per-frame render scratch + cached cursor line/visual-column so a
      frame does not repeat rope/display-width queries.
- [x] Cursor shape/visibility control (Vim block/bar) and full-width statusline.
- [x] Current CLI exposes the renderer via `v [first h w]`.
- [x] Input decoder foundation for printable UTF-8, ctrl keys, arrows,
      delete/home/end/page keys.
- [x] Terminal lifecycle foundation: alternate screen and POSIX raw mode helper.
- [x] Terminal sizing via ioctl with `COLUMNS`/`LINES` fallback.
- [x] Dedicated render/input/load/save benchmark harness (`zig build bench-render`).

### Undo / history
- [x] `UndoTree` (own object/file): persistent undo/redo **tree** — a new edit
      after an undo starts a new branch instead of discarding the redo side.
- [x] Root node snapshots the state at open; every node stores its transition
      (`edits`) plus caret-before/after and a seq id + timestamp hook.
- [x] Insert-mode grouping (`beginUndoGroup`/`endUndoGroup`) + insert/forward-delete
      coalescing so a typing session is one undo unit. Backspaces coalesce into a
      single reversed-store edit (no O(n) prepend, ~28x faster backspace path).
- [x] `undo` / `redo` restore the caret; `jumpToState(seq)` navigates to any
      recorded state via O(depth) LCA traversal (future undo-tree UI).
- [x] O(1) `findBySeq` (seq→node index); iterative teardown/traversal
      (stack-safe on very deep histories).

## Performance optimization opportunities (spotted in review)

Ordered roughly by expected impact. None of these are implemented yet.

- [ ] **Leaf-cursor codepoint iterator.** `CodepointIterator.next` currently calls
      `codepointAt` → `byteAt` per byte, i.e. `O(log n)` tree descents per byte.
      Range-based `graphemes`, sub-range `displayWidth`, sub-range
      `countCodepointsUtf8`, and large-line visual-column mapping all pay this.
      Replace with an iterator that holds the current leaf + path and walks leaf
      slices directly (`O(bytes)` instead of `O(bytes·log n)`).
- [ ] **Node free list / recycling.** Edits abandon path-copied nodes; under
      random edits `allocated_nodes` grows ~25× live nodes until `compact()`.
      Recycle abandoned `Node`/`LeafData` into free lists reused by split/concat.
- [ ] **Automatic compaction threshold.** Track live-vs-allocated ratio and
      auto-compact (or emit a hint) when it crosses a bound, so long sessions
      don't leak slab memory.
- [ ] **Single-descent `byteOffsetForLineColumn`.** It currently performs two
      `byteOffsetForLine` descents plus a `byteAt`; fold into one descent that
      returns the line start and scans within the line.
- [ ] **SIMD newline scanning.** `countNewlines` / `rebuildNewlineBits` are scalar
      loops on the load and rebuild paths; vectorize with `@Vector` for `build_*`
      and large-insert throughput.
- [ ] **Incremental newline-bit updates on mid-leaf edits.** `insertIntoLeaf`
      rebuilds the whole leaf bitset for non-append inserts; shift bits instead.
- [ ] **Table-driven Unicode predicates.** `continuesGrapheme`, `isWideCodepoint`,
      `isCombiningMark`, etc. are linear range switches; replace with generated
      lookup tables (also the correctness upgrade path below).
- [ ] **Forward byte/line iterator for rendering.** Rendering loops should stream
      via a leaf iterator instead of repeated `byteAt` (each `O(log n)`).
- [ ] **Per-line layout cache.** `byteOffsetForLineVisualColumn` copies up to 1 KiB
      per call; cache per-line width layout, invalidated on edit, for cursor
      motion and rendering.
- [ ] **Branch/leaf node packing.** `Node` is a 64-byte union; a tagged-pointer or
      typed-pool split could shrink branch footprint further (measure first).

## TODO (features / correctness)

### Cursor & editing safety
- [x] Cursor generation stamping to detect staleness after non-cursor edits
      (`Cursor.sync` clamps to a codepoint boundary on generation change).
- [x] Cursor-local delete/backspace fast path (`deleteBackward`/`deleteForward`).
- [x] `Buffer.Cursor` drives an internal `Rope.Cursor` for typing.
- [ ] Multi-cursor support (multiple carets sharing one buffer + fast paths).
- [ ] Word-wise movement/deletion (`moveWordLeft/Right`, `deleteWord`).

### Undo / history
- [x] Persistent undo/redo tree with branch preservation (see editor-core).
- [ ] Undo-tree navigation UI (render branches/timestamps; the model is ready).
- [ ] `undolevels`-style cap: prune oldest branches to bound memory.
- [ ] Persist the undo tree to disk (nvim-style `undofile`).
- [ ] `.`-repeat: record the last change command for replay.
- [ ] Change events / edit deltas for observers (highlighting, diagnostics).

### Unicode completeness (needs generated UCD tables)
- [ ] UAX #29 grapheme break tables (replace heuristics; add `GraphemeBreakTest.txt` conformance).
- [ ] UAX #11 East Asian Width tables (replace `isWideCodepoint`).
- [ ] NFC/NFD normalization (decomposition + composition tables; `NormalizationTest.txt`).
- [ ] Grapheme-aware cursor movement helpers (prev/next grapheme).
- [ ] Optional line/char/grapheme count metrics cached on branches (like newlines).

### Buffer features
- [x] Basic file I/O: load from / save to disk with path + dirty-state tracking.
- [ ] Streaming file I/O for very large files (avoid full-buffer save flatten).
- [ ] Atomic save (write temp sibling, fsync, rename) + backup/swap policy.
- [ ] Encoding detection + conversion (UTF-8/16, BOM, CRLF handling).
- [ ] Line-ending awareness (LF/CRLF) in line metrics.
- [ ] Search (literal + regex) over rope without full flatten.
- [ ] Range replace / batch edit API.

### Terminal UI / rendering
- [x] Render pipeline foundation: cells, styles, rects, viewport renderer.
- [x] Raw terminal mode + alternate screen lifecycle foundation.
- [x] Diff renderer (previous/current surfaces -> minimal ANSI updates).
- [x] Input decoder (keys, modifiers foundation, escape sequences).
- [x] View tree foundation for editor, statusline, sidebars,
      telescope-style picker overlays.
- [x] Full-screen editor event loop using raw mode + decoded keys.
- [x] Correct editor viewport sizing from the layout rect; cursor visibility and
      terminal cursor placement track the rendered viewport.
- [x] Vim-like cursor visibility/shape control and full-width styled statusline.
- [x] Incremental invalidation via dirty rects (`FrameRenderer.markDirty` +
      `AnsiRenderer.renderDiffRects`); the editor loop marks editor/status/command
      regions so present only scans changed regions.
- [ ] Component scheduler with focus, z-order traversal, and command routing.
- [ ] Per-component dirty tracking driven by buffer generation ranges.
- [ ] Syntax/highlight spans layered over viewport cells.

### Robustness / production
- [ ] Fuzz tests (`std.testing.fuzz`) for edits and Unicode boundaries.
- [ ] Property tests against a reference model over long random sessions.
- [ ] Explicit OOM/error-path testing with a failing allocator.
- [ ] Thread-safety story (read snapshots vs. writer) if concurrency is needed.

### Benchmarking / comparison
- [ ] Compare against gap buffer and piece table under the same harness.
- [ ] Add CSV/JSON benchmark output + regression baseline tracking.
- [ ] Real-file workload benchmarks (source trees, logs, minified JS).
- [ ] Latency percentiles (p50/p99) in addition to best-of-N.

## Status

The byte and UTF-8 layers are fast and well-tested. Grapheme segmentation,
display width, and normalization are intentionally **heuristic / incomplete**
and clearly labeled via `Rope.unicode_support`; full compliance requires
generated Unicode data tables (see TODO). The structure is ready to build an
editor core on, with the optimization list above as the next performance work.
