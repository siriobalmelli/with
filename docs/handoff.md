# Handoff: D27/#740 emit-C roundtrip — generic intrinsics, fat fn values, allocator scan

## #747 session-3b: BATTERY 7 RED — bridge-object worker hits #743-class corruption

Battery 6 red was regex find_all (fixed, committed with the migration
tools). Battery 7 red: llvm-bridge-object AND clang-bridge-object
workers die rc=139 — worker.stderr shows the exact #743 signature
(corrupt vec header, origin=drop#struct __drop_struct_220, ASCII
garbage cap/elem) ~4s in. Batteries 1-5 ran these lanes green, so the
groundwork batch (ComptimeValue clones / borrowed evaluator helpers /
InternPool clone-returns) either shifted the latent #743 allocation
alignment or introduced a REAL teardown double-free in the comptime
action machinery.

NEXT (in order):
1. Repro standalone: `with build :llvm-bridge-object` (worker mode —
   the crash is in the spawned worker; run the worker command from
   out/command/llvm-bridge-object args if needed).
2. DIFFERENTIAL first: git worktree at the pre-groundwork commit (the
   one before "compiler/std: #747 groundwork"), run the same step —
   green there = my regression, red = #743 alignment luck. If mine:
   WITH_DEBUG_ALLOC=1 + tools/debug_drop.w on the repro; suspect list =
   comptime_value_clone at slot/extras sites (double-ownership of
   extra_start/extra_count-referenced payloads is the obvious hazard:
   clone copies the EXTRA RANGE INDICES, so two values now claim the
   same extras — if extras teardown frees per-value, that is the
   double-free).
3. Fix, both-worlds check, RERUN battery 7. Then the worktree flip +
   fixpoint driver per the plan below.

NOTE the suspicion in 2: comptime_value_clone is a SHALLOW clone of a
value whose extra_start/extra_count reference shared extras storage —
review every site where the ORIGINAL and the CLONE both live at
teardown; the fix may be that extras teardown must not free through
value handles at all (or clones must not duplicate range claims).

## #747 session-3 state: groundwork COMMITTED, flip is 3 local hunks

The de-Copy groundwork (139 seed errors to 0) is COMMITTED and both-
worlds-valid; the drop glue is in-tree but DORMANT. The flip itself is
now exactly 3 hunks to re-apply in src/Sema.w: (1) remove TY_STR from
the is_copy prim line, (2) add explicit `if tk == TY_STR: return 0`
below it (the tail DEFAULTS TO COPY), (3) add `if tk == TY_STR: return
1` in type_needs_drop after `let tk`. With those applied and :dev
rebuilt, stage1 check src = **5,694 errors** (4,378 use-of-moved,
333 field-through-borrow, 110 Vec.push, dominated by CImport 1652 /
main.w 507 / ComptimeEval 358 / ConanClient 262 / CCodegen 245).
NO read-only-param fix-it exists yet — NEXT: build the param-borrow
migrator (analyze parameter facts/effects -> rewrite read-only plain
`str`/str-bearing-struct params to &T, D5 keeps call sites identical),
run it over src, then hand-fix the residue. Then: battery on the
groundwork commit FIRST (pending — de-Copies are ownership-adjacent:
ALONE + :move-audit/:drop-audit), then the flip batch with its own
bracketed audits, lib/std de-Copy tail (JsonView/Package/ProjectInfo/
Diagnostics), corpora, un-pin, reseed, roundtrip.

## #747 session-2 state (2026-08-02, superseded above)

DONE since the census: (a) is_copy needed an EXPLICIT `TY_STR → 0`
branch — removing it from the prim line fell through to the fn's
DEFAULT COPY tail, which is why drops never scheduled (bindings gate on
is_copy_frozen, MirLower:5370) and the strdrop smoke leaked 2000×16 B.
(b) The 37 move sites → 0 via ~12 clone insertions (movers were
field-to-local/field-to-field assignments; with_str_clone / *_owned_text
idiom; the REAL mover is often lines above the flagged use — the checker
flags USES). (c) De-Copy round 1: 8 str-bearing `impl Copy` removed
(std Match, CiProjectSymbol, CompilationConfig, TypeKey, ValueKey,
LockEntry, ComptimeControl, ComptimeValue).

OPEN, in order:
1. **Seed compat**: the SEED now rejects src with 139 errors — the
   de-Copied TypeKey/ValueKey cascade through InternPool
   (`st.type_keys.push(key)` moves; `st.type_keys.get(id)` returned-view
   lifetimes). Fixes must pass BOTH worlds (seed str=Copy, stage1
   flipped). Iterate against the SEED's list (`with check src/main.w`)
   — it is the complete set; the flipped stage1 aborts early on the
   stale embed until the next full :dev.
2. stage1's :dev at 71s was incremental and did NOT re-embed
   lib/std/regex.w (Match impl still in the embedded copy) — force the
   embed (touch lib/std/regex.w or clean the embed target).
3. Then: lib/std de-Copy tail (JsonView json.w:22, Package/ProjectInfo/
   Diagnostics build.w:255-270 — surface when corpora/build.w check),
   corpus sweep, un-pin emitc cap, drop-audit before/after, battery
   ALONE, reseed, roundtrip.
4. Bug found en route: the SEED miscompiles a `with -e` one-liner with
   Vec[str] pushes + for-loop + .get() ("LLVM function verification
   failed after MIR cleanup for main") — file an issue with the repro
   from the session log (scratchpad command history).
5. strdrop smoke (post-fix) still to re-verify: expect leak count=0
   under --debug-alloc once drops schedule.

## #747 STR FLIP IN PROGRESS — WORKING TREE DIRTY (2026-08-02)

The flip's mechanics are implemented and sitting UNCOMMITTED in the
working tree (seed-checks clean; flipped stage1 builds):

- Sema.w: `is_copy` drops TY_STR from the Copy primitives line;
  `type_needs_drop` returns 1 for TY_STR (comment block explains).
- rt/rt_core.w: `with_str_free` / `with_str_free_drop_origin` — free the
  data ptr ONLY if `rt_payload_start_is_owned` (literals/views/moved-from
  no-op), then blank the {ptr,len} place. Leak-not-free under
  WITH_ALLOC_SYSTEM=1 (documented).
- CodegenDispatch.w: `mir_emit_str_free_ptr` + ensure-fns, dispatched
  from `mir_emit_drop_ptr_for_sema_type` on TY_STR (before the Vec
  branch), drop-origin tagging mirrored from the Vec pattern.

**Measured fallout (the big surprise): flipped stage1 check of src =
only 37 `use of moved value` errors** (24 main.w:1840-1980 one build-
graph loop; 4 compiler/Backend.w:51/135/195/238; 3 Codegen.w:1103-1104
(`self.source_file.slice` twice); 3 CodegenDispatch.w:17693-17694;
2 Analysis.w:532/816; 1 compiler/Frontend.w:1650). is_copy-only flip
produced ZERO errors — move tracking keys on type_needs_drop.

Diagnosis so far: NOT one cause. build_graph_dispatch_standard_target
already takes &BuildGraphTarget, so main.w's loop moves come from
something else (loop-carried field move via `completed_targets.push(
target.name)` in earlier iterations, or build_cache_record's params —
UNVERIFIED). Codegen.w:1103-04 suggests a field-read+method-receiver
interaction. Next: diagnose each site with the flipped stage1
(`out/bootstrap/bin/with-stage1 check src/main.w`), fix per D5 doctrine
(observers borrow; genuine retention spells the owned copy via the
*_owned_text idiom), iterate. THEN: #747 scope items 2 (de-Copy
JsonView/Package/ProjectInfo/Diagnostics + ~95 impl Copy sweep — the
compiler now REJECTS Copy on str-bearing structs automatically) and 3
(delete the cap pin in emitc_migrate_compiler_c). Then corpus check,
:move-audit/:drop-audit BEFORE AND AFTER per the ruling, full battery
ALONE in its batch, reseed, roundtrip.

Updated 2026-08-01 (second pass). **#750 work item 1 (D29 scaffolding) is
IMPLEMENTED and committed** (`6430d1ee` compiler, `67816feb` corpora); the
exact-tree battery was launched on `67816feb` (build → fixpoint → test →
move/drop audits → emit-C gates; log in the session scratchpad
`battery.log`). If green: `:test-green`, `:last-green`, `:update-seed`,
`:install-user`, then the roundtrip (`:emit-c-roundtrip`, cap pinned off
per D28) is unblocked.

## #750 WI-1 implementation map (all scaffolding-labeled)

- **Gate**: `decl_visible_from_current_gated` (Sema.w) — §18.2 allow-list
  (`sema_prelude_gate_allows_name`; c_void + assert_matches_failed are
  lowering support), std blindness (std never sees user decls), explicit-
  import reachability via `module_visible_no_prelude` (skips synthetic
  prelude edges). Externs exempt (global C symbols; frontend dedups decls).
  Compiler demands (regex literals) use `lookup_named_type_ambient`.
- **Fix-it diagnostic**: `'X' requires an explicit import (§18.1); add: use
  std.m.X` — from the identifier tail, emit_unknown_type_error, struct
  literals, and the generic-base path (was an ungated flat fallback).
- **Shadow coexistence** (user type redefines a closure name): per-tier
  provenance recorded at registration (`type_sym_tier_mask`,
  `type_tid_is_std`, `type_decl_nodes_by_tid`, `impl_extra_is_std`);
  shadowed syms route is_copy/Drop/trait-selection/struct-literal decl
  nodes through the tid's tier (`select_trait_impl_tiered`, uncached).
  Codegen: std-tier decl registers LLVM types under `name$std`
  (`shadow_reg_sym`/`shadow_lookup_sym`); `declare_function_at` wraps in
  the fn's own tier context so signatures match call sites. Frontend Box/Rc
  ad-hoc drops REMOVED; fn decls still shadow by decl-drop (flat sig
  table, #751).
- **Sweeps**: src/build/tools self-import-complete (HashMap 994 sites, 12
  files; int_to_string/parse/StringBuilder tail). Corpora: 181 behavior +
  242 other/examples files migrated via tools/insert_std_uses.w +
  tools/sweep_gate_corpus.w, zero stuck; import-free originals of the 181
  forked to **test/d_acceptance/** (quarantined; no lane globs it; #752
  un-quarantines).
- **Migrator**: `migrate_apply_std_use_fixits` (main.w) applies the fix-it
  to its own output in-process, loud on non-convergence. **One-liners**:
  -e/-n/-p synthesized header now imports the ambient vocabulary.
- **Fixtures**: behav_prelude_shadow_types.w (user Regex/CString/
  StringBuilder/Box/Rc shadows incl. Copy-vs-std-Drop), 
  behav_prelude_import_gate.w (gated names via imports, ambient §18.2,
  regex literal).
- **#753 filed+mitigated**: view-liveness whole-pool span scan matched
  same-named idents across files (insertion-sensitive phantom errors);
  guard added, victim annotated. Known WI-1 gaps (documented, B/D fix):
  trait names stay flat-ambient; enum-variant gating deferred; shadowed
  GENERIC types conflate; same-named methods across tiers conflate
  ((sym, method)-keyed tables); comptime/emit-C shadow paths untiered.

## Battery 1 verdict (on 67816feb) and the fix batch

build ✔, fixpoint ✔, move-audit ✔. RED: behavior 19/937, drop-audit
(all cells COMPILE-FAIL), emit-c-smoke. Every red is classed and none is
an ownership regression:

1. **Shadow-generic crash** (`is_copy_frozen miss`, behav_generics +
   issue59_* + generic_* — tests define `type Box[T]`/`Pair[T]`): tiered
   lookups returned the other tier's generic base → fresh generic insts
   minted post-freeze. FIXED: `record_type_decl_tier` only for
   `tp_count==0` decls (generic name reuse keeps flat behavior; #751).
2. **rlimit unknown-type** (c_import tests + imported_alias): ba67bcb2's
   std.libc record skip fired for in-place c_import where nothing imports
   std.libc. FIXED: `g_ci_translate_migrate_mode` scopes the skip to
   migrate (`ci_translate_in_migrate_mode`; gate the CImport.w:2112 skip
   on it — VERIFY the CImport.w side actually consults it, the flag is
   set in CiMigrate.w but the skip-site condition still needs the check
   added!).
3. **Sweep-missed implicit-main tests** (behav_implicit_main,
   nonassoc_parenthesized, string_builder, regex_language_semantics,
   raw_ptr_arithmetic?, opaque_struct_call?): `check` cannot parse
   implicit-main files, so the sweep skipped them. Fix: feed each failed
   test's harness stderr (out/test-graph/behavior-tests/*.stderr) to
   tools/insert_std_uses.w --apply, or sweep via a build-based check.
4. **drop-audit COMPILE-FAIL wall**: its GENERATED probes used gated
   names bare. FIXED: resource_prelude()/the second builder now emit
   use-lines.
5. **emit-c-smoke red**: the #753 phantom-view class again, new victim —
   "cannot mutate `self` while `kind` is a live view" label @2885:9
   (file not captured; found during the lane's stage1 action under the
   SEED, whose checker predates the guard). Fix like expire_borrows:
   locate the victim (`kind` binding at :2885 in some src file the lane
   compiles) and annotate the binding (`let kind: i32 = ...`).

## Battery 2 + 3 (all fixes landed through commit "ss16 module form")

Battery 2 (on the batch-2 fixes): all green EXCEPT 6 compile-error tests
(imports added; committed) and emit-c-smoke fixtures (imports added;
committed). Battery 3 (283d09e0): build/fixpoint/move/drop/ecsmoke/
ectest/ecfix ALL GREEN; :test red on exactly 2 spec tests, both fixed
and committed since: spec_ss14 (Task import added by hand — its check
resolves Task via the async-lowering side door while MIR does not; seam
noted in #750) and spec_ss16 (module-form `use std.builtins` — the
symbol form trips pre-existing #754: symbol-form closure import +
c_import cluster drops an unrelated root fn from the pool; SEED
reproduces; full notes in the issue).

## #754: FIXED (decls_share_source_file origin-class guard)

Root cause: impl_node_for_method_decl span-containment adopted root fns
into c_import-generated impls (synthetic spans vs real file ids — the
#753 disease family). Fix + full notes in the closed issue; spec_ss16
back on symbol-form as the live pin. Debug instrumentation stripped.

## Battery 4 (post-#754-fix): one red, resolved

All green except :test → cli-selfhost-build-w-tests 'build-w-toolfs-archive'
with a corrupt-vec-header panic. Chain: the extract_tar_gz action's
GENERATED zlib_gunzip helper (template in lib/std/build.w) used
StringBuilder bare → gate error → action failed → pre-existing #743
(teardown corruption after a FAILED action) fired on top. Battery 3
passed on a cached helper compile. Template now imports StringBuilder;
fixture green end to end. #743 gained a deterministic 3s reproducer
(recipe on the issue); it reproduces under the untouched seed too and
stays open/unrelated. The #754 guard was verified NOT causal (revert
still panicked) before the true chain surfaced via --debug-alloc.

## RESEEDED — and the roundtrip's next blocker

Battery 5 + :test rerun (after the prelude-output edge-fixture import
fix, harness data only): ALL GREEN. Reseed complete: seed + installed
compiler are **v0.15.1-g21751b3be** — the first gate-enforcing
toolchain. (:last-green needed a :fixpoint refresh first because the
:test rerun re-stamped the stages; the :last-green failure ALSO stacked
the #743 teardown corruption, consistent with its failed-action
trigger.)

Roundtrip attempt on the reseeded toolchain: FAILED at ~600s in
`run_emit_c_roundtrip_action` with `panic: integer overflow: i32
multiplication out of range` during comptime evaluation, right after
compiler-version-sources (i.e. in/around `emitc_build_compiler_c_workspace`,
BEFORE migrate). Facts: direct out-of-process emission
(`with build out/gen/versioned_main.w --emit-c -o …`) SUCCEEDS, so the
overflow is in the driver's comptime execution under the NEW compiler —
either a comptime-arithmetic regression in the reseeded binary or a
pre-existing silent overflow now correctly checked. The panic carries
no source location (worth fixing while there). Multiply scan candidates
found so far: lib/std/build.w:1300 `tool_pax_parse_decimal` (i32
decimal parse) — unconfirmed. Next: rerun the action with lldb break on
the overflow panic (or add comptime panic locations), localize the
multiply, fix, rerun `with build :emit-c-roundtrip` under keep-awake.

## Roundtrip attempt 2 (post-overflow-fix): #747 is the wall

The comptime-overflow root cause was the migrate CHILD: session_strdup
cap*2 in i32 past 2^30 tracked strings, driven by the un-indexed
record/typedef lookup family x #749 per-member-expr probes. Fixed
(indexed + i64 counters, fixture-verified, committed). The step now
dies at max RSS 94.4 GiB (OS kill; 68.4 GB was the old surviving
peak) — transient-str retention (D28 bridge) outgrew the machine.
Roundtrip migrate stays red until #747 (str flip) — which D29
sequences next anyway. Repro: stage1 migrate out/emit-c-roundtrip/
main.c with -I runtime -include out/gen/wl_decls.h --no-c-export,
WITH_MEMORY_LIMIT_BYTES=0.

## Next steps (historical: battery 5 plan)
2. All green → reseed: `:test-green`, `:last-green`, `:update-seed`,
   `:install-user`. Post-reseed the seed enforces the gate (src/build/
   tools already import-complete, both #753 victims annotated).
3. Roundtrip under keep-awake: `with build :emit-c-roundtrip` — migrate
   now self-applies import fix-its; #749's rlimit-gate/c_void loose ends
   may surface there and belong to #750 WI-1.
4. Then #747 (str flip) per the D29 sequence.

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
- **#749's initializer side is DONE** (`2545b05b`): the bridge enumerates
  C11 anonymous members (cursor-identity detection — clang's
  "(unnamed ...)" spelling drift was silently demoting every carrier to
  `opaque`), carrier decls render faithfully with synthesized union
  members, initializer lowering is designator-driven (designators
  recovered from source text; libclang's C visitor never surfaces them
  as cursors), C's `{0}` is a zero marker, and designated-init
  assignments print as memset + field stores — no dependence on With
  field defaults. The 5 MB fixture C migrates with **zero**
  untranslatable functions (the class was 1,111 across the compiler C).
  Migrator basic/core lanes green.
- **#749 access side is DONE** (`6bed71c9`): member refs render the full
  path through anonymous members (`x.anon_0.payload0`), and
  prelude-colliding C declarations rename with `@[link_name]` (POSIX
  `write` etc.). Migrator lanes green.
- **#750 (the roundtrip's gate) is RULED — D29.** Eric's directive (verbatim
  in docs/decisions.md D29) sets the destination: implicit std availability
  as a lowest-priority exact-match fallback tier, precedence
  lexical/generic-params → current-module → imports/aliases → prelude →
  unique std fallback; spec §18.2 now states it (the spec is deliberately
  ahead of the implementation). Staging: **work item 1** (#750, the
  roundtrip gate, label commits *scaffolding*) removes flat std injection,
  enforces the §18.2 prelude exactly, ships an insert-`use` fix-it the
  migrator auto-applies, migrates the affected behavior tests via the
  fix-it, and forks the import-free originals into a quarantined
  D acceptance corpus — acceptance criteria are in the issue comment.
  **#751** (canonical module-qualified identity, record-don't-start,
  after #747) and **#752** (fallback-tier activation, blocked on #751,
  `with update` pinning-imports migration is a hard ship-with requirement)
  are filed. Rejected forever: option C / lean-prelude modes, prelude
  expansion, fuzzy/ranked resolution, flat injection. Prior findings
  stand: the module-drop generalization is unsound for non-leaf modules
  (reverted, boundary documented in Frontend.w); `ba67bcb2`'s migrator
  dedups (c_void, rlimit) are kept, their two loose ends folded into
  work item 1; the extern-shadow diagnostic is a deliberate guard, so
  `write_` renames stay.
- Environment note: long runs on this box die ~10 min after session
  activity stops (traveling laptop — lid/sleep/battery). Take an
  `mcp__adrafinil__keep_awake` hold for any long verification and
  release it after; launch detached with a log file regardless.

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
