# Handoff: D27/#740 emit-C roundtrip — generic intrinsics, fat fn values, allocator scan

Updated 2026-07-30. This replaces the 2026-07-29 handoff, whose "exact next
steps" were overtaken by four root causes found while executing them. Current
single remaining blocker for the roundtrip: issue #744 (migrator memory
retention).

## Read this first

Read `AGENTS.md` before doing anything. The rules that mattered most in this
continuation: locate the exact wrong line before editing; a build is
verification, not experimentation; never pipe a verdict-bearing command
through head/tail (fish `$status` reports the last pipe stage — this bit
again this session and is recorded in memory).

## What landed (newest first)

| Commit | Change |
| --- | --- |
| `22d09501` | c-migrate: decl-name lookups use one-pass owned-copy indexes (was: full-table rescan per call, permanently session-retaining a spelling per probe — 82M+ live strings); decl cursors memoized (was: fresh store per query, ~125M duplicated cursors via subtree cache rebuilds). Output byte-identical on a prelude-scale migration. |
| `6eb6158c` | build: `emitc_parse_export_function` ends its element view before moving the params Vec — the post-D27 checker rejects the old shape, and the first post-flip reseed wedged every `with build` until this fix (see #745). |
| `d3d55c6a` | emit-c: fat thunk signatures render through `c_decl` (pointer-to-array params/returns need the name inside the declarator; caught by the `emit-c-array-ref` edge fixture during the first battery). |
| `d39fd508` | rt: large-allocation ownership checks binary-search a sorted range table (was: unsorted append + linear scan per check — quadratic on the compiler-C migration, ~90% of a 43-minute run). |
| `abf1e2e2` | emit-c: DYN_DOWNCAST/OPT_FILTER/VEC_MAP/VEC_FILTER/VEC_FOLD fail emission nonzero instead of emitting compilable abort() lies. The compiler uses none of them. |
| `29a369b7` | emit-c: GENERIC_CALL lowers for real (sizeof/alignof → C sizeof/_Alignof via `resolve_type_level_arg_expr_frozen`; transmute → object-representation memcpy with `_Static_assert` size pin; everything else fails loudly). With fn values are now fat `{fn_ptr(ctx, …), ctx}` pairs matching native's closure convention (`Codegen.w` `gen_fn_to_fat_ptr_thunk`): TY_FN typedefs are pair structs, named-fn materialization registers a static C thunk, indirect calls go through `.fn_ptr(.ctx, …)`, CK_FN operands meeting fn-typed demands (assign/arg/aggregate/enum-payload) render pair literals. TY_EXTERN_FN stays a bare C pointer. emit-c-smoke gained a compile-and-run fixture (sizeof/alignof values, transmute bit round-trips, spawn_os/join through the pair). |
| `1d4fa519` | sema: generic type-argument builtins (sizeof/alignof, nameof, transmute, chan) record their call type in `typed_expr_types`. Unrecorded, MirLower's fallback re-derived void and `lower_fn_with_sig` swapped in the implicit default return: tail-position `transmute` returned zeroed bits SILENTLY, natively, on every seed. `test/behavior/behav_transmute_tail_position.w` pins all six spellings. |

## The three root causes, in discovery order

1. **Sema never typed generic-builtin call nodes.** Symptom: emit-C transmute
   dest temp typed `int32_t`; deeper symptom: native tail-position transmute
   (prefix/brace/block unsafe forms, and plain in an `unsafe fn`) silently
   returned default-initialized values. Pre-existing on the v0.15.1 seed.
   Chain: `SemaCheck.check_call` builtin early-returns → `typed_expr_types`
   miss → `MirLower.fallback_expr_type` NK_CALL → `call_return_type` (no
   NK_INDEX arm) → void temp → `lower_fn_with_sig` fall-through default.

2. **emit-C fn values diverged from native layout.** Native: 16-byte fat pair,
   fn_ptr always closure-convention, plain fns get thunks. emit-C: bare 8-byte
   C fn pointer. Observable via `sizeof[fn() -> i32]()` (16 vs 8) and fatal for
   `std.thread.spawn_os`'s `transmute[RawFn0I32](worker)`, which every
   prelude-bearing program compiles in. The old backend hid this behind the
   GENERIC_CALL abort stub; the new `_Static_assert` surfaced it at C-compile
   time. Fixed by mirroring the native convention (commit `29a369b7`).

3. **Allocator large-range ownership scan was quadratic.** The roundtrip's
   `migrate-compiler-c` step hit the 900 s timeout; `sample` showed ~90% of
   CPU in `rt_payload_start_is_owned`'s linear walk of the (unsorted) large
   range table at 13–44 GB heap. Slab ranges had already been converted to
   sorted+binary-search for exactly this reason; large ranges now match
   (commit `d39fd508`). Post-fix the full compiler-C migration completes in
   ~660 s wall, inside the step's 900 s budget. The dominant cost is now
   `ci_str_matches_at`/`ci_find_str` (real migrator string scanning).

## Verification state (all on the committed tree at `d39fd508`)

Green so far:

- `with check src/main.w`, `with build :dev` at each step
- `with build` (full, 570 s) after the allocator fix
- `with build :emit-c-smoke` — including the new generic-intrinsics fixture
  (runs the emitted binary; spawn_os/join over a real OS thread)
- `with build :emit-c-test` (327 s) — whole compiler emitted as C under the
  fat fn-value backend, built by host cc, version parity + hello
- `with build :emit-c-fixpoint` (340 s) — C-built compiler re-emits
  byte-identical C (thunk naming/order deterministic)
- Native regression `behav_transmute_tail_position.w`: passes on fixed
  compiler, fails on the seed exactly at the four tail forms

Red, with the root-cause chain fully mapped (#744, investigation comment):

- **Primary cause: transient `str` drops do not free** until the pending
  #691 str flip (Vec buffers flipped; str awaits the Copy-with-str ruling).
  Migrating the 48 MB compiler C allocates ~68 GB of never-freed transient
  strings (measured peak 68.4 GB with the cap disabled) — the 64 GiB
  default cap kills it by construction. The migrator was simply the first
  workload big enough to expose the staged flip.
- Two migrator-side amplifiers were real and are fixed in `22d09501`
  (byte-identical output proven on a fixture-scale migration).
- Final whole-compiler verification is blocked ON THIS DEV BOX by an
  environment reaper: macOS 26.5 SIGKILLs long CPU-pegged processes at
  ~10–11 min regardless of nohup/launchd (66 looped attempts, all rc=137,
  no jetsam log). From an interactive terminal, run:
  `WITH_MEMORY_LIMIT_BYTES=0 with build :emit-c-roundtrip` — the migrate
  step needs one uninterrupted ~11-minute run.
- D28 (Eric's ruling, 2026-07-31) settled the fork: the migrate step pins
  its cap off until the #691 str flip (`bdcb9b35`); the flip itself is
  #747; ephemeral view-structs (the view-token shape) are #748.
- #746 (positional record literals) is FIXED (`e7bdd9c9`): the field scan
  continues past self-referential typedefs, and unrecoverable-record
  initializers fail loudly instead of emitting invalid With.
- The roundtrip's next critical-path item is **#749**, and its true root
  is DECL-level: `collect_field` (ClangBridge.w:993) keeps only
  `CXCursor_FieldDecl` children, and a C11 anonymous member has no
  FieldDecl cursor — so the enum-carrier structs translate as 1-field,
  wrong-sized types and every `.payloadN` access dangles. Fix bottom-up
  per the issue: (1) surface anonymous members in the bridge's field
  enumeration, (2) let the existing synth-type path render the union
  member, (3) designator-aware (or enum-variant) init lowering. Fast
  repro: migrate the 5 MB `emit_c_generic_intrinsics_case` fixture C
  (~2 min); it stops loudly at `str_to_cstring__83`.

Battery and reseed: DONE on `d3d55c6a`.

- `with build` 358 s, `:fixpoint` 314 s, `:test` 630 s (33 lanes),
  `:move-audit`, `:drop-audit`, `:emit-c-smoke`, `:emit-c-test` 180 s,
  `:emit-c-fixpoint` 160 s — all green in one serial run.
- The first battery attempt (on `d39fd508`) failed exactly one lane:
  `emit-c-array-ref` caught the thunk declarator bug, fixed by
  `d3d55c6a`; the battery was rerun from the top on that commit.
- `:test-green`, `:last-green`, `:update-seed`, `:install-user` completed;
  seed and installed compiler are `with v0.15.1-gd3d55c6ab`.
- The roundtrip has never been green (it is the campaign objective, not a
  regression gate); the reseed bar was the AGENTS.md success checklist
  plus the audits, all green.

## Watch-outs for the continuation

- Background-shell verdicts: two direct `with migrate` runs were SIGKILLed
  (~10–11 min) by the session environment, NOT by the code — run long steps
  nohup-detached with a log file, or through the build graph.
- The migrate step is CPU-heavy for ~11 of its 900 s budget. Do not run the
  battery concurrently with the roundtrip; contention could push it over.
- `out/debug_emit_c_generic.w` (ignored) still exists as the reduction; its
  tail-position `debug_transmute` exercises the Sema fix. `.fixed3.c` is the
  current good emission (cc -fsyntax-only clean).
- Issue #743 (comptime teardown `corrupt vec header` after a failed action)
  remains open, unrelated, reproduced pre-D27.

## Completion bar (unchanged from previous handoff)

- emitted compiler C contains no executable placeholder for paths the
  compiler uses ✔ (generic intrinsics real; five unsupported families now
  fail emission; compiler uses none of them)
- unsupported C-backend paths fail generation nonzero ✔
- sizeof/alignof/transmute behaviorally correct in compiled emitted C ✔
  (fixture runs)
- C compiler, C-to-With migrated compiler, and normal compiler pass their
  test lanes — pending roundtrip
- emit-C fixpoint ✔; full roundtrip self-host equality — pending
- normal build/fixpoint/test and ownership audits — pending final battery
- last-green, seed, installed compiler updated only from the exact verified
  commit — pending
