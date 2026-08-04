# Handoff: D27/#740 emit-C roundtrip — generic intrinsics, fat fn values, allocator scan

## SEED BROKE AND RECOVERED: g43df7f0d8 could not orchestrate (0f663361 fixed it)

The g43df7f0d8 reseed shipped a binary that blows the 64 GiB limit on
ANY `with build` — groundwork made evaluator READ paths deep-clone
(lookup_value/extra_value_at → comptime_value_clone → with_str_clone),
quadratic on the embedded-stdlib generator's string accumulator. The
hole (#757): batteries only ever run the release binary as a spawned
pure-compiler child; its FIRST act as build.w orchestrator is after
reseed. Recovery: the direct compile+link path was unaffected —
`with build src/main.w -O1 -o with-fixed` bootstrapped a fixed binary,
which orchestrated battery 11 (fully green) → RESEEDED g0f663361e
(seed + installed, orchestration-probed). comptime_value_share copies
the value struct WITHOUT cloning text (pre-#747 Copy read semantics;
store sites still clone; flagged loudly under the flipped classifier).
Probe any future seed candidate as ORCHESTRATOR before :update-seed
(rm out/lib/rt_core.o; candidate build :rt-core-object) until #757's
gate lands.

## #747 Phase C steps 1+2 DONE: census 1232 -> 571 (747-flip @ 76d4bf1c)

Trajectory: 1232 -> 1059 (step 1, extern flips, 7d8d085e) -> 578
(wrapper round 1, 2e135933) -> 571 (round 2, 76d4bf1c; wrapper DRY).
Every round passed the seed gate (`src/main build :stage1` in wt-flip);
moveprobe still shows exactly the intentional move error. Skip-list was
never needed (no wrap ever broke the seed build).

Step 1 (extern ABI flips, the whole with_* wrong-argument bucket dry):
fs family (17)/getenv/setenv/exec family (7)/eprint/write/write_stdout/
ewrite/print_str/println_str/str_len/str_hash now take &str; rt bodies
read through a str_ref_view shim (BOOTSTRAP INTERIM slot spelling, see
with_str_clone_ref). Learned the hard way:
- The frontend dedups extern decls PER SYMBOL — every decl everywhere
  (src, lib, rt-internal, tools, test) must flip together. SemaCheck.w's
  stale consuming with_regex_compile decl was the "regex.w:162" census
  error.
- Codegen-EMITTED symbols (str byte_at/contains/starts_with/eq/concat/
  slice, fmt_buf_write_str, str_clone) keep their ABI; erroring call
  sites respelled to method/operator form; CCodegen COut.write got a
  with_fmt_buf_write_str_ref rt twin (clone would leak per write).
- SEED-BUILT + WORKSPACE-LINKED binaries (with-sha256, stage1) must not
  call runtime symbols the seed's frozen embedded prelude also declares:
  prelude decl wins dedup with pre-flip ABI against flipped rt = silent
  garbage I/O. with-sha256 now uses own-decl with_write_stdout +
  with_libc_write. INVERSELY: a tool with flipped decls built by `src/
  main build/run` INSIDE the worktree links the worktree's flipped
  out/lib rt only in the build-system path; a plain seed build links the
  seed's embedded (unflipped) rt — build wrapper/driver tool binaries
  from OUTSIDE the worktree, run them with cwd inside it.
- The seed cannot auto-borrow an if-expression temporary at a &str arg
  (one hoist in SemaDiag.w:600); literals and call-result temporaries
  auto-borrow fine in both worlds (probed).

Step 2: tools/wrap_diag_spans.w (in wt-flip) parses flipped-stage1 text
diagnostics (kind + --> span + caret run length) and wraps spans in
with_str_clone_ref(...) back-to-front per file, inserting the extern
decl once per touched file. Kinds: Vec.push (label-gated &str), D22
call-arg (with_str_clone(span) is RENAMED to clone_ref, not double-
cloned), D22 struct-field, struct-literal/assignment mismatch (RHS
only), return mismatch (bare ident/field only). 376 edits total.
Seed-era traps inside the tool (all commented): #755-class Vec[str]
element reads feeding consuming positions (annotated bindings + splice
helper), unannotated element binding = live view (slot-swap needs
`let tmp: i32`), and NEVER pass a $var file list unquoted in this
fish shell — it arrives as ONE newline-joined argument (this, not a
compiler bug, was every "tool silently did nothing on N files" mystery;
use `... | tr '\n' ' ' | xargs`).

Census 571 residue (stage1 check src/main.w in wt-flip, census8.txt in
the session scratchpad): 234 return-type (complex tails the wrapper
correctly skips — 61 CImport, 14 ProjectConfig, 11 ComptimeEval, 11
CiMigrate, 10 Link, 10 Codegen, 10 CiIR, 9 SemaCheck; mostly
`xs.get(i)` view tails in `-> str` fns and multiline if/match tails),
149 use-of-moved, 50 struct-literal mismatch (multiline literal heads +
shorthand fields the wrapper skips), 22 if-copy, 47 HashMap get/
contains/insert (&K observer flips or clone-at-call), 10 typed-binding
mismatch, 10 D22 assignment, 8 mutate-while-view (Lsp doc_text), ~30
misc (compiler_analysis_run/sha256_hash_str/Vec.contains args, eprint,
loop-carried moves).

NEXT SESSION (Phase C step 3, hand-fix in this order):
1. Return tails: clone the view tail (`with_str_clone_ref(xs.get(i))`)
   or respell accessor fns to return &str where callers only observe.
   The 61 CImport + 14 ProjectConfig are bulk-similar shapes.
2. HashMap.get/contains/insert &K observer flips (D22 says get/contains
   take &K — check whether the collections flip from 457b7233 already
   covers the K=str case, else clone at call).
3. use-of-moved: read-before-move reorder or clone at the move site;
   the two loop-carried classes (`prefix`, `path`) first.
4. Then the Phase C tail per the plan below: lib/std de-Copy leftovers,
   corpus sweep, un-pin emitc cap, flipped stage1->stage2, audits,
   battery ALONE, reseed. After reseed: respell rt str_ref_view/
   clone_ref honestly (`s as *const str`), and re-audit consuming-str
   extern calls with owned args for the leak class (extern callees
   never free; flipped decls remove the leak for read-only params).

## #747 blocker RESOLVED: cast fixed, stage1 healthy, census 1232 (03267bb1)

The "mixed-convention extern ABI" was not an ABI bug. Two real causes,
both fixed in 03267bb1 on 747-flip:
(1) CodegenDispatch's RK_CAST TY_STR branch extracted the str DATA
pointer for ANY pointer target; after auto-deref of a &str source,
`s as *const str` returned the text bytes as a header address. Now a
*const str/*mut str target is address-preserving (operand place
address via mir_try_place_ptr_for_ref); *const u8 targets keep the
data pointer. Verified by running: seed-built repro SIGBUSes,
stage1-built prints the data byte. The FROZEN SEED still has this bug
— it also miscompiles unflipped programs (any `(s: &str) as *const
str`); heals at reseed once the flip branch lands.
(2) The flip left the owned-era read `*(&s as *const *const u8)` at 34
&str-param sites (InternPool.store = every interned symbol!, Sema,
Llvm/ClangBridge, std regex, rt clone_ref/slice_ref). For &str, `&s`
is the SLOT address, so single deref = header ptr as data — interning
memcpy'd pointer bytes, hence interior-NUL/SIGSEGV per site. All
respelled to the both-worlds `**(&s as *const *const *const u8)`;
owned-local sites (tmpl/probe_line, rt str_data family) correctly keep
single deref. rt clone_ref/slice_ref carry a BOOTSTRAP INTERIM
comment: respell honestly via `s as *const str` AFTER reseed (rt
objects are seed-built; the seed miscompiles the honest spelling).
moveprobe: exactly the intentional move error, rc=1, no crash. First
true census (stage1 check src/main.w): **1232 errors** — 286
return-type, 184 Vec.push, 154 use-of-moved, 109 D22
field-through-borrow, 67 struct-literal, 47 fs externs, 43 assignment,
34 HashMap get/contains, 31+ view-origin, 25 if-copy. NEXT: Phase C
per the plan below — (1) flip fs/str extern decls (~47 errs), (2)
build tools/wrap_diag_spans.w wrapper tool (~700 errs), (3) hand-fix
residue.

## #747 flip: std CLEAN, src residue 1319 (branch 747-flip @ 7d3e754b)

Phase A done: embedded std checks CLEAN under the flip (probe: only the
intentional move error). regex.w was the whole prelude fallout — 32
params borrowed; Regex.compile/compile_flags DENYLISTED as consuming
(D5: they retain); clone() + Captures.subject + borrowed tails use
with_str_clone_ref; 18 slice calls → with_str_slice_ref. rt additions
(both-worlds-valid): with_str_clone_ref(&str), with_str_slice_ref(&str)
in rt_core.w (read header via `s as *const str` double-deref — probed
spelling); with_regex_{compile,match_spans_alloc_at,group_name_to_index,
substitute} flipped to &str WITH matching std extern decls (std-only
wiring; with_str_slice is codegen-emitted — ABI kept, ref twin added).
rt objects are seed-built (unflipped) so rt bodies only need unflipped
validity this campaign.

Phase B done: driver fixpoint 5685 → 1319 in one mechanical round
(denylist never engaged — residue is not consumer-shaped). Residue
buckets: 311 return-type (borrowed tails in `-> str` fns), 185
Vec.push(&str), 154 use-of-moved, 88 view-origin §21.1, 76+34 D22
field-through-borrow, 67 struct-literal, 43 assignment, 34 owned-to-
ref-binding (diagnostic suggests exact fix), 33 with_fs_read_file-class
externs, 25 if-copy, 19 HashMap.get.

GATE discovered after the WIP commit: the MIGRATED src is not yet
UNFLIPPED-valid — the seed build of stage1 from it fails at 39 unique
sites (`if expression of type str cannot produce &str`, owned-to-ref
bindings): &str params now join owned strs in if-expressions and
rvalue-borrow demands. These overlap the 1319 flip residue; every fix
must be BOTH-worlds-valid. Fix these 39 FIRST (site list captured in
the flip session's scratchpad unflipped_80.txt; regenerate any time
via `src/main build :stage1` in the worktree — the seed's own errors
ARE the list). Collections observer flips (HashMap/BTreeMap get+
contains &K, HashSet contains &T, StringBuilder.push_str &str)
committed as 457b7233; their std-body fallout is unknown until stage1
next builds.

BLOCKER (worktree, branch @ 1416af84): `&str` ACROSS THE EXTERN
BOUNDARY IS MIXED-CONVENTION. The 39 both-worlds sites are FIXED
(agent commit a614d2fa: 35 var-init clones + 4 if-hoists; note the
seed cannot auto-borrow an if-expression temporary at a &str arg — 
hoist to a binding). Seed stage1 build is GREEN. But the built stage1
CRASHES running the clone_ref calls: reading the &str param as
pointer-to-header faults with string bytes as the address; reading it
as the fat pair panics interior-NUL — caller marshalling and callee
prologue disagree PER SITE. This is D6's per-path ABI divergence, in
compute_fn_abi/PassMode for &T-of-str on extern fns. NEXT SESSION:
(1) `with check --dump-abi` on a clone_ref caller + the rt definition
in the worktree, compare verdicts; (2) fix in compute_fn_abi ONCE (or
rule that extern fns cannot take &str and switch the ref-variant
surface to `*const str` + `&raw const` call sites); (3) re-verify
moveprobe shows the intentional move error, then census. The
pre-crash residue trajectory: 1319 before the collections observer
flips (get/contains &K, push_str &str) — true current residue UNKNOWN
(the '0 errors' census was a crash artifact, rc=139/1).
Also: the frozen seed panicked corrupt-vec on its DIAGNOSTIC path
during agent round 1 — one more #743 failure-path data point.

Phase C next (in order, after the ABI blocker):
1. Flip fs/str extern decls in src + rt signatures (with_fs_read_file
   etc., read-only paths) — same recipe as the regex four (~50 errors).
2. Build tools/wrap_diag_spans.w: parse flipped-checker diagnostics
   (error kind + primary span), wrap the spanned expression in
   with_str_clone_ref(...) by byte edit for kinds: Vec.push arg, D22
   call-arg/struct-literal-field, assignment/literal mismatch, borrowed
   return tails (~700 errors). Iterate to dry. Clones are CORRECT;
   #748 view tokens recover perf later. Model: tools/
   migrate_method_arg_moves.w (diagnostics+spans).
3. Hand-fix: use-of-moved (read-before-move reorder or clone at move),
   view-origin escapes, if-copy joins (clone one branch).
4. Then: lib/std de-Copy tail (build.w Package/ProjectInfo/Diagnostics/
   Workspace; JsonView = flip-time design ?), corpus sweep, un-pin
   emitc_migrate cap, flipped stage1→stage2 attempt, :move-audit/
   :drop-audit, battery ALONE on the flip merge, reseed, roundtrip.

Worktree: scratchpad wt-flip, branch 747-flip (flip 4406d2f6 + share
cherry-pick + WIP 7d3e754b). Driver artifacts in scratchpad:
flip_files_src.txt (94), flip_denylist.txt, flip_scratch/round.txt
(the 1319 residue diagnostics). Flipped stage1: wt-flip/out/bootstrap/
bin/with-stage1 (rebuild ~2.5min via `src/main build :stage1` in wt).

## #747 flip branch LIVE: scratchpad/wt-flip @ 747-flip

Worktree wt-flip (branch 747-flip) = 1f47f706 + flip commit 4406d2f6
(3 Sema hunks + re-wired TY_STR drop dispatch) + share fix cherry-pick.
Flipped stage1 building; then tools/drive_param_borrow_fixpoint.w with
flip_files.txt (209 files src+lib), empty denylist, flip_scratch —
all in the session scratchpad. Residue after fixpoint = hand-fix list;
then lib/std de-Copy tail (build.w Package/ProjectInfo/Diagnostics/
Workspace at 259-301; JsonView is D27-ruled Copy — flip-time design
question, not mechanical), corpus sweep, un-pin emitc_migrate cap,
:move-audit/:drop-audit bracketing, battery ALONE, reseed, roundtrip.

## Battery-7 red RESOLVED: two bugs, one signature (daf9fc56 fixed mine)

lldb rt_munmap tracing pinned the deterministic :llvm-bridge-object
rc=139: the #747 groundwork's "dormant" TY_STR drop dispatch in
mir_emit_drop_ptr_for_sema_type was reachable KIND-FIRST via
struct-field drop glue (no classifier re-check), so an ~80KB
source-text str — a shared view — was munmapped mid-frontend and
double-freed (backtrace: with_str_free_drop_origin ←
Zcu.compile_source_frontend_mode). FIXED in daf9fc56 by unwiring the
dispatch; the runtime hooks + mir_emit_str_free_ptr stay as inert
infrastructure to wire ONLY with the is_copy/type_needs_drop flip.
Bridge repro now 5/5 green, fresh :llvm-bridge-object green.

#743 proper (action-error teardown corrupt-vec panic) is REAL and
pre-existing — it reproduces on the pre-flip seed in a worktree with
no #747 code (repro on the issue). It is confined to the failed-action
teardown path and does not block green batteries. Correction posted on
the issue.

#755 filed: Vec[str].get(i) element view passed unmarshalled (raw
place ptr) to a str-consuming param → invalid LLVM IR. check passes,
codegen misses the D22 materializing load. Blocks migration one-liners;
same class gets heavy exercise under the flip — land before/with #747.

RESEEDED on g43df7f0d8 (seed + installed): battery 10 fully green
(build/fixpoint/move-audit/drop-audit/test) + test-green/last-green.
Three fixes landed across batteries 8-10:
- daf9fc56: the UAF unwiring above.
- 0fd69d43: pretty-name extraction sliced the PRIMARY file at std
  body-node spans (find_decl_index knows only top-level decls);
  set_pretty_symbol poisoned syms compiler-wide when the bytes read
  `let <ident>` — regex.w's locals printed as val/ca/view and failed
  dump_typed_d22_contextual_copy. Fix: fall back through
  local_file_id (the checker's per-decl context). #756 filed for the
  sibling compute_method_origins cross-module span-containment
  adoption (pre-existing, needs its own battery).
- 43df7f0d: groundwork's clone-returns missed the FOUNDATION
  InternPool twin (only internals-tests compile it; no battery had
  reached that lane since the de-Copy). type_key_clone/
  value_key_clone at both resolve tails.
Lane-abort lesson: a battery that dies at lane N leaves every later
lane UNPROVEN — after fixing lane N's red, flush the whole :test
before the next battery instead of discovering one lane per battery.

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

## SESSION-RESUME (2026-08-04p): #750 E1102 COHERENCE FIX LANDED (duplicate-impl scan tier-discriminates shadowed syms) + THE FULL BODY-LEVEL ROUNDTRIP CENSUS IS IN: 188,427 errors, only 9 kinds, three mechanical migrator classes cover 99.7% — the migrate-fix worklist is now concrete

MAIN LINE: healthy (docs-only commit here). Worktree recipe unchanged.

#747 STATE: branch `747-flip` @ 31fc99c6 (one fix commit this session; tree
clean). Seed gate `src/main build :stage1` rc=0 146.7s; stage2 rebuilt rc=0
129.3s; /tmp/flip-stage2-probe = that stage2. Census gate: stage1
`check src/main.w` ok 69.3s / 48.5 GB (matches 04k/04m/04n/04o exactly).
Worktree path unchanged (scratchpad/wt-flip; main_migrated.w and all census
tools in the same scratchpad).

THE #750 FIX (31fc99c6 — MAIN-LINE-worthy, must ride the flip merge):
`collect_impl_decl`'s "Record direct impl" duplicate scan (SemaDecl.w
~2361-2381) treated any prior record under the same interned type NAME as a
duplicate, so the migrated file's one `impl Copy for RegexFlags` collided
with the prelude's impl for std's DIFFERENT RegexFlags (lib/std/regex.w:43).
Fix composes with the D29 tier machinery instead of bypassing it: for a
shadowed sym (`type_sym_tier_mask == 3`) the scan now skips records whose
`impl_extra_is_std` tier differs from the tier of the type the gated lookup
resolves from the impl's own module — the exact pattern the function's
existing Copy/Drop conflict checks already use (`type_sym_is_shadowed` +
`type_tid_std_tier(resolve_alias(lookup_named_type_visible(...)))` +
`impl_record_matches_tier`). Unshadowed syms keep the flat scan
bit-for-bit. VERIFIED: shadow-coexistence repro (user RegexFlags + impl
Copy alongside std's) compiles AND runs; shadowed true-dup AND flat
true-dup both still E1102 (e1102repro.w / e1102dup.w / e1102dup2.w);
behavior smoke 3 c_import + 3 plain green on the rebuilt probe.
(behav_c_import_auto_constructor rc=139 is PRE-EXISTING — 04l invalid-free
residual family, evidence behavior_diffs.txt `DIFF probe=1 base=0` and
battery.log; the fix only adds a `continue` to an error scan, accepted
programs untouched.)

THE CENSUS (the campaign's number): `WITH_MEMORY_LIMIT_BYTES=118111600640
/tmp/flip-stage2-probe check main_migrated.w` rc=1, 312.5s, 2.27 GB peak,
ZERO panics, ZERO E1102 — the decl gate cleared and the body phase ran to
completion. 188,427 error diagnostics (188,165 after collapsing 262
adjacent #759-style double-renders — the decl-phase doubling barely touches
body errors; warnings double much more: 448,267 rendered / 297,540
adjacent-distinct). Only 76 of all 636,694 diagnostics are located in
embedded-std; the rest are in main_migrated.w. Kind table (census_04p.w
bucketer; full tables in census-04p-buckets.txt):

  111524  type mismatch in assignment
   62359  wrong argument type in call to '_'
   13942  undefined variable
     559  return type does not implement Default
      30  return type mismatch
       5  match arms do not establish one compatible owned result type
       4  unknown type 'WithVec'
       3  right operand of ++ must be str
       1  @[effect] pin mismatch (preamble 'worker')

ROOT CHARACTERIZATION (exact lines; these are MIGRATOR classes — the next
migrate-fix worklist; do NOT hand-edit main_migrated.w):
1. bool-local int assignment (dominant, most of the 111k): C `_Bool`
   locals migrate to `var x: bool = false` but every assignment feeds a C
   int expr — `(x = 0)`, `(x = (if cond: 1 else: 0))`. See
   main_migrated.w:484 (decl) vs :505/:522 (stores).
2. runtime-extern signature collision (most of the 62k): the roundtrip
   file redeclares the with_* runtime ABI (`extern fn with_memcpy(dst:
   *i8, src: *i8, n: i64)`, line 75) and calls collide with the
   prelude/internal signatures under the flat extern namespace
   (with_memcpy/with_str_len/with_str_eq/with_vec_*...). See :1064. The
   76 embedded-std-located errors are the same collision seen from std's
   side. This is the #750 EXTERN lane (issue Fix: delete extern-shadow
   diagnostic / resolve externs by tier) — sema-side, not migrator-side.
3. param-name mismatch (the 13,942 undefined variables): the signature
   emitter names parameters from the C source (`__param_c` for C param
   `c`) while bodies reference index-derived `__param__1`. See
   `pub fn wl_context_dispose(__param_c: c_longlong)` :326 vs :343.
4. uninitialized non-Default locals (559): `var __local__0...: with_str`
   with no initializer (:30895; Result_CString__CStringError_ :60135).

Top error-bearing regions (single-file input, so the "top files" table is
by enclosing migrated fn and its module prefix): Sema 37,769; Codegen
25,186; ci 19,728; CCodegen 12,114; MirBuilder 10,087; ComptimeEvaluator
9,460; Parser 5,846. Top fn: Codegen_mir_emit_call_term__34534 (2,189).

SESSION ARTIFACTS (scratchpad): census-04p.time (256 MB stderr = the
diagnostics), census-04p-buckets.txt (tables), census_04p.w + dedup_04p.w
(With scanners), e1102repro.w/e1102dup.w/e1102dup2.w, seedgate-04p.log,
s2rebuild-04p.log.

NEXT: classes 1/3/4 are migrator fixes (fix `with migrate`, re-migrate,
re-census — never hand-edit output); class 2 is the #750 extern lane in
Sema. RESIDUALS: 04l instance I (deps-manifest UAF) untouched;
behav_c_import_auto_constructor still red (04l family).

## SESSION-RESUME (2026-08-04o, SUPERSEDED by 04p above): #747 CHECK-SCALE i32 OVERFLOW ROOT-CAUSED + FIXED (fn_param_defaults key `param_start * 1000` overflowed at 3M-line scale); the migrated 3M-line compiler source now CHECKS to a clean diagnostics verdict — 6 errors, ONE root defect, and it is #750 (name-keyed trait coherence), which is now the roundtrip census's first wall

MAIN LINE: healthy (docs-only commit here). Worktree recipe unchanged.

#747 STATE: branch `747-flip` @ 01c8248f (one fix commit this session; tree
clean; seed gate `src/main build :stage1` rc=0 148.5s; stage2 rebuilt rc=0
137.0s; /tmp/flip-stage2-probe = that stage2). Census: stage1
`check src/main.w` rc=0 70.9s 48.5 GB (matches 04k/04m/04n exactly).
Worktree path this arc:
/private/tmp/claude-501/-Users-eric-with/17fe1e89-880a-4f21-a24e-7646e0127fda/scratchpad/wt-flip
(main_migrated.w, logs, and probe tools live in that same scratchpad dir).

THE OVERFLOW, ROOT-CAUSED at the line: `AstPool.set_fn_param_default` /
`get_fn_param_default` (src/Ast.w:1426-1434) packed their map key as
`param_start * 1000 + param_idx` in i32. `param_start` is an extra-array
index; past ~2.147M entries the multiply trips the overflow trap. On the
freshly migrated compiler source (103.5 MB, 3,011,786 lines) `check`
panicked `integer overflow: i32 multiplication out of range` at ~191 s
with ZERO diagnostics (lldb `b with_panic` bt: get_fn_param_default <-
astpool_clone_deep <- Sema.comptime_transform_module <-
Zcu.compile_source_frontend_mode). FIX (01c8248f): key widened to i64
(`(param_start as i64) * 1000 + (param_idx as i64)`), map to
HashMap[i64, i32]. Whole-src survey for the class (composite-key i32
multiplies): the ONLY sema/check-path instance. Two latent CODEGEN-path
siblings left untouched (codegen isolation discipline; check never runs
them): Codegen.w:1354 `type_sym * 10007 + trait_sym` (overflows past
~214k interned syms) and the bitpack `bit_offset * 65536 + bit_width`
pair (Codegen.w:2235, CodegenDispatch.w:1398; overflows for bitfields at
struct bit-offset >= 32768). Widen those when the codegen path first
meets roundtrip scale.

MIGRATE POST-WRITE SHARES THE SITE (no rerun needed): the rc=134 panic
after the output write was the fix-it pass — main.w:3404-3406
`migrate_apply_std_use_fixits` runs `compiler_analyze_file` over the
output, i.e. the same frontend path through comptime_transform_module.
One fix covers both.

THE VERDICT (the campaign's number): `/tmp/flip-stage2-probe check
main_migrated.w` rc=1, 216.8 s, 1.78 GB peak RSS, NO panic; byte-identical
diagnostics across the lldb and plain runs (deterministic). 6 error
diagnostics = 3 unique kinds x2 (the x2 is #759, decl-phase double-render):

  count  kind
    2    duplicate implementation of trait for type [E1102]   (line 58353, impl Copy for RegexFlags)
    2    type 'Result_RegexFlags__RegexError__anon_0' cannot implement Copy: field 'payload0' is not Copy  (59141)
    2    type 'Result_RegexFlags__RegexError_' cannot implement Copy: field 'anon_0' is not Copy           (59143)

ONE ROOT DEFECT, AND IT IS NOT THE MIGRATOR'S: the file contains exactly
one `impl Copy for RegexFlags`; the E1102 collision is with the PRELUDE's
lib/std/regex.w:43 impl — Sema's direct-impl coherence table is keyed by
the bare interned type NAME (impl_lookup, SemaDecl.w ~2365-2371, and the
duplicate scan ignores impl_extra_is_std). That is exactly #750
(prelude/std names not shadowable; its Fix section already prescribes
E1102 keying on resolved type identity). The other two errors are pure
cascades (rejected impl leaves user RegexFlags non-Copy; the Result
union/struct wrapping it then fail). 5-line repro errors on the
main-world installed compiler too — pre-existing, not flip-specific.
Evidence commented on #750; the diagnostic double-render filed as #759.
The check aborts after the decl phase ("check failed during
compilation"), so the full body-level census is UNREACHABLE until the
#750 coherence fix lands. Do NOT hand-fix the migrated output.

NEXT GATE for the roundtrip: fix #750's E1102 keying (resolved type
identity, or at minimum skip is_std entries in the duplicate scan), then
re-check main_migrated.w for the real body-level census. The decl phase
runs in ~217 s at 1.78 GB, so iteration at full scale is cheap now.

SESSION ARTIFACTS (this scratchpad): verdict-check.log (lldb run),
verdict-plain.log, bucket_diags.w (diagnostic bucketer, `with run`),
e1102repro.w, dblrender.w.

RESIDUALS: 04l instance I (deps-manifest UAF) untouched. Migrate rerun
not required this session (output already on disk; post-write panic
explained above).

## SESSION-RESUME (2026-08-04n, SUPERSEDED by 04o above): #747 LATE-TRANSLATE BLOW-UP ROOT-CAUSED + FIXED (ci_lookup_known sliced the whole registry per scanned entry; slice5 413 s -> 125 s, translate linear again); 24.4 MB (51% of input) migrates clean under 12 GB — full-input verdict run is READY for the orchestrator

MAIN LINE: healthy (docs-only commit here). Worktree recipe unchanged.

#747 STATE: branch `747-flip` @ 7af076d5 (one fix commit this session; tree
clean; seed gate `src/main build :stage1` rc=0 158.0s; stage2 rebuilt rc=0;
/tmp/flip-stage2-probe = that stage2). Census: stage1 `check src/main.w`
rc=0 72.9s 48.5 GB (matches 04k/04m exactly).

THE LATE-TRANSLATE WALL (04m's residual + the 110 GiB cap-kill at 7846 s
wall / sys 5471 s vs user 2359 s), ROOT-CAUSED at the line:
`ci_lookup_known` (src/CImport.w:4804 pre-fix) spelled its per-entry
prefix test as `ci_starts_with(known.slice(pos, known.len()), key)`.
Under owned str (#747) every .slice() is an owned copy, so ONE lookup
allocated+memcpy'd+freed the ENTIRE remaining registry string once per
scanned entry — O(entries x |registry|) bytes of alloc/mmap churn per
call, on the per-expression type path (lldb-attached stacks, 4/5
mid-translate: with_str_slice/alloc/free under ci_lookup_known <-
ci_normalize_translated_type_name <- CiTypePool.type_from_libclang <-
lower_value_expr_ir <- ci_trans_stmt_via_ir). A pre-fix full-input
sample at the 70-min mark: 96% of CPU in mmap/slice/alloc/free under
ci_trans_stmt_via_ir, mmap alone 51% — churn payload grows with the
registry as decls accumulate = the cumulative time superlinearity AND
the sys-dominated TB-scale page traffic (755M page reclaims).

FIX (7af076d5): match in place — `ci_str_matches_at(known, pos, key)`.
Same bytes compared, zero allocation. Outputs BYTE-IDENTICAL (cmp) on
slice2 + slice5 + combo12.

CURVES (fixed stage2; RSS peaks are the fix-it sema, unchanged):
- slice2 (2.17 MB): 37 s -> 37 s (small scale was never lookup-bound)
- slice5 (5.06 MB): 413 s -> 124.9 s; sys 207 s -> 2.7 s
- combo12 (11.75 MB): ~1100 s -> 288 s; translate now LINEAR
  (slice5 125 s : combo12 288 s : combo16 translate 133 s for 24.4 MB)
- translate-end committed: 130 MB @5 MB, 347 MB @11.75, 935 MB @24.4 —
  linear with content density (90-160 AST nodes/KB region variance;
  cursor-kind histogram of a 3.8M-cursor session dump shows a normal
  expression-dominated shape, dedupe healthy, no pathological kind)
- combo16 (24.4 MB = 51% of the full input, preamble + windows 1-6):
  COMPLETES rc=0 under a 12 GB cap, 53 MB output written; translate
  133 s; peak ~5.2 GB (fix-it sema of the 53 MB output).

HOW IT WAS CORNERED (for the record — the blow-up resisted slicing):
- 12 windowed slices (preamble + each ~6 MB region at fn boundaries)
  covering ALL 1.97M definition lines: every region clean standalone
  (peaks 1.46-1.57 GB) -> not construct/region-local.
- biggest emitted function (24.6k lines, Codegen_mir_emit_call_term)
  alone: 110 s / 486 MB -> not function-size.
- win12 content re-padded to ORIGINAL byte/line offsets in a 47.6 MB
  whitespace file: clean -> not offset-proportional.
- phase-bracketed lldb (rt_alloc_committed_bytes at
  ci_collect_demoted_types / ci_migrate_translate_vars /
  ci_migrate_normalize_output breakpoints): translate-end committed
  linear at every scale -> cumulative-scale churn was the only
  superlinear load; attach-at-phase bt named the line.
- the 04m full run died BEFORE the output write (no .w file), i.e.
  inside migrate_c_file, at ~the extrapolated end of pre-fix translate.

READY FOR ORCHESTRATOR — full-input verdict run (fixed probe):
  WITH_MEMORY_LIMIT_BYTES=118111600640 /usr/bin/time -l \
  /tmp/flip-stage2-probe migrate out/emit-c-roundtrip/main.c \
  -o <scratchpad>/main_migrated.w -I runtime -include out/gen/wl_decls.h \
  --no-c-export     (cwd /Users/eric/with, or absolute -I/-include paths)
Expect: parse+prescan minutes, translate ~5 min (linear), then the
fix-it pass (up to 3 full sema passes of the ~95 MB output) dominating
wall; committed at translate end ~2-2.5 GB; peak in fix-it sema ~10-15 GB
projected. Then `check` the output with the probe and COUNT the errors
(the count is the roundtrip's next stage — do NOT fix them there).

RESIDUALS / JUDGMENT CALLS:
- The pre-fix 118 GiB LIVE committed at full scale was never reproduced
  at <=24 MB (post-fix committed extrapolates to ~2.5 GB). A pre-fix
  capped-lldb full-input trap (bp rt_alloc_report_limit_exceeded, bt)
  was in flight to name the pre-fix live site exactly but was torn down
  by the harness ~105 min in; not rerun (2 h pre-fix diagnostic vs the
  orchestrator's verdict run with the FIXED binary answering the only
  question that matters). If the verdict run still trips a cap, run
  <scratchpad>/fulldiag.lldb — it breakpoints the limit-exceeded
  branch and prints the offending allocation's full backtrace.
- Fix-it sema of the migrated megamodule is now the peak-memory phase
  (~5.2 GB @53 MB output) and runs up to 3 full compiler_analyze_file
  passes + renders every warning (04m residual, unchanged; Eric's call).
- 04l instance I (deps-manifest UAF) untouched.
- Slice artifacts for future sessions (session scratchpad): win1-12.c,
  combo12/14/16.c, win12pad.c (offset-preserving builder mkpad.w),
  gslice1.c, phase_mem5/combo16/curdump lldb scripts, cursors.bin
  kind-histogram tool curhist.w.

WHAT REMAINS for #747 (delta from 04m): unchanged list, minus the
late-translate migrate wall (fixed above); the full-input migrate
verdict + error count of the migrated output is the next gate.

## SESSION-RESUME (2026-08-04m, SUPERSEDED by 04n above): #747/D28 MIGRATE MEMORY WALL ROOT-CAUSED + FIXED (261M duplicated cursor stores; 12.4 GB -> 333 MB on a 2 MB slice) + three quadratic time rebuilds killed; full 47 MB attempt IN FLIGHT at session end

MAIN LINE: healthy (docs-only commit here). Worktree recipe unchanged.

#747 STATE: branch `747-flip` @ c0c29868 (one fix commit this session; tree
clean; seed gate `src/main build :stage1` rc=0 280.0s on the committed
content; stage2 rebuilt rc=0; /tmp/flip-stage2-probe = that stage2).
Census: stage1 `check src/main.w` rc=0 70.1s 48.5 GB (un-pressured;
matches 04k's 48.5 GB — seed world retains by design until reseed).

THE MEMORY WALL (04l's 110 GiB cap-kill), ROOT-CAUSED at the line:
`store_cursor`/`store_type` had un-memoized minters (with_ci_type_declaration
ClangBridge store_cursor; every with_ci_type_* store_type) handing out a
FRESH index per query. Each fresh index had cold children caches, so every
subtree walk re-collected and re-stored whole subtrees. Measured by
conditioned-bp reads of rt_alloc_committed_bytes + session counters at
dispose entry (phase_mem lldb scripts in the session scratchpad):
2.17 MB slice = 261,647,123 stored cursors + 261,599,055 child_indices
for 10,165 decls (~25.7k stores/decl) = cursors 8.37 GB + child arrays
~3.1 GB of the 12.44 GB peak. Committed profile per phase (slice2):
parse 4.9 MB -> macro+prescan 5.53 GB -> translate end 12.44 GB ->
dispose 14.6 MB (ALL of it session-lifetime, freed at dispose — the
44 GB+ committed on the full input was the same curve x22 decl count).

FIX (c0c29868, all outputs BYTE-IDENTICAL before/after on slice2+slice5):
1. ClangBridge.w: store_cursor/store_type dedupe via FNV open-addressing
   index tables keyed on node identity bytes (CXType pad excluded);
   cursor-spelling memo per stored index (clang_getCursorSpelling's
   DeclarationName printer alone was 34% of translate CPU);
   with_cimport_decl_name routes through the memoized decl cursor;
   session allocs use sizeof[CImportSession]() (were hardcoded 232).
2. CImport.w ci_str_replace: parts+join (was byte-by-byte `result ++ c`
   rebuild — ci_migrate_normalize_output made it O(n^2) over the WHOLE
   output: 9 of slice2's 10.5 min, TBs of memcpy, lldb-verified
   x1=942856 x3=1 per concat).
3. CImport.w ci_trans_stmt_via_ir: fn-var registry snapshot by LENGTH
   (append-only during stmt lowering; ci_temp_reset only at fn entry) —
   was a whole-registry clone PER STATEMENT.
4. Zcu.w render loops: ONE Source per file, not per diagnostic
   (each rebuild cloned the whole file text + recomputed line offsets;
   the migrate fix-it pass renders 32k+ warnings on slice5 output).

CURVE (peak RSS / wall, byte-identical outputs at each step):
- slice2 (2.17 MB): 12.31 GB / 633 s  ->  333 MB / 37 s
- slice5 (5.06 MB): ~13.4+ GB / never finished -> 1.03 GB / 413 s
- Memory is FLAT (bounded by the fix-it phase's sema of the output).
- Slices: head -n cuts of out/emit-c-roundtrip/main.c at `^}$` decl
  boundaries (lines 11727 / 136952 / 345688 / 786001 for 2/5/10/20 MB);
  slice files + all logs/samples in the session scratchpad.

RESIDUAL (report, not fixed — investigation budget reached):
- Translate TIME still superlinear (slice2 37 s -> slice5 413 s, x11 for
  x2.33): late-translate samples show ~60% in with_str_slice + rt_mmap/
  munmap churn on >4 KB payloads under ci_trans_stmt_via_ir (leaf-only
  attribution; sample cannot unwind With frames). Suspect class: owned
  materialization of large extent/source-text slices per statement in
  huge emitted-C functions (with_ci_cursor_source_text family / big
  .slice() owned demands). A conditioned rt_mmap bp ($x0>500000) is too
  slow to reach mid-translate; next session should bp with_str_slice
  with a length condition on the LIVE process after attach-at-phase, or
  add a temporary counter. NOT a memory problem anymore.
- The fix-it pass prints every warning of the migrated output (32k on
  slice5, likely 300k+ full-input) — linear now, but the stderr flood
  dwarfs the useful output; consider whether migrate's analyze pass
  should render warnings at all (Eric's call, behavior change).
- 04l's instance I (deps-manifest UAF) untouched, still next mechanical
  wall for the c_import corpus files.

FULL-INPUT ATTEMPT (the ONE detached run): started at session end,
pid-tracked keep-awake hold taken;
  WITH_MEMORY_LIMIT_BYTES=118111600640 /usr/bin/time -l
  /tmp/flip-stage2-probe migrate out/emit-c-roundtrip/main.c
  -o <scratchpad>/main_migrated.w -I runtime -include out/gen/wl_decls.h
  --no-c-export
Logs: <scratchpad>/fullrun.log (+ fullrun_rss.log, 2-min RSS samples;
fullrun.start epoch). Expect: memory fine (est. <10 GB), wall dominated
by the residual translate superlinearity (hours). Verdict criteria per
the campaign: completes under cap; then `check` the output with the
probe and COUNT the errors (that count is the roundtrip's next stage —
do NOT fix them in this campaign).

WHAT REMAINS for #747 (delta from 04l): unchanged list, minus the
migrate memory wall (fixed above); plus the translate-time residual.

## SESSION-RESUME (2026-08-04l, SUPERSEDED by 04m above): #747 INSTANCE H FIXED (session_make_str double-ownership) — 29/44 c_import invalid-free tests recovered + migrate UNBLOCKED past the 4.5s dispose wall; instance I (deps-manifest UAF) forensically characterized, NOT yet fixed

MAIN LINE: healthy (docs-only commit here). Worktree recipe unchanged.

#747 STATE: branch `747-flip` @ b3178278 (one fix commit this session;
tree clean; seed gate rc=0 189.8s on the committed content). stage1
rebuilt; /tmp/flip-stage2-probe rebuilt (rc=0). Probe self-check
rc=0 71.6s 428 MB. Stage1 census rc=0 78.5s 25.6 GiB (better than
04k's 48.5 GB; ran under memory pressure, not chased). Probe run-smoke:
string_interp/assoc_type/async/-e all rc=0.

FIX 8 (b3178278, instance H) — the predicted bridge-helper
double-ownership, one site: ClangBridge.w session_make_str fabricated
an OWNED str (raw [2]i64 -> *const str) over the SAME allocation
session_strdup registers in (*s).strings. Under the flip every
receiving local's drop freed the payload, then with_cimport_dispose's
tracked-strings loop freed it again — the whole
"invalid free: pointer is not an allocated payload start" family in
with_cimport_dispose <- cimport_collect_macros_from_libclang.
Evidence chain: WITH_DEBUG_ALLOC verdict (DOUBLE FREE size=64,
first_drop=drop#struct, second=<untagged>); trap-hook lldb bt named
with_str_free_drop_origin in collect_macro_def as first free and
dispose as second; payload content at the trap = the macro location
string ("/tmp/with_cimport_macro_XXXX:2:9") = the session_make_str
result robbed at collect_macro_def scope end. Fix: session_make_str =
make_str(p) — a -> str return transfers ownership; nothing tracked.
BOOTSTRAP INTERIM: seed world (no drops) leaks the copy until reseed,
bounded to c_import compilations under stage1.

FAMILY VERDICT (the 44 sweep files from 04k, probe check, user cache
restored): 29 pass stable (was 0). Remainder is NOT one bucket:
- ~9-10 files = INSTANCE I, the deps-manifest UAF family (below);
  flaky by heap shape/cache state (macros_no_cc flips ok/fail between
  runs; auto_constructor/nullable_ptr_none/sdk_header/
  imported_alias_struct_field/raw_ptr_arithmetic/issue44/issue114/
  spec_ss16 x2 fail rc=139 or interior-NUL rc=1).
- 5 files = issue59_demo_*: now surface `type 'BindEntry' cannot
  implement Copy: field 'name' is not Copy` — CORRECT flip diagnostics
  (test-source de-Copy fallout class, not crashes; they died at the
  dispose free before H).

MIGRATE SMOKE (the 04k blocker): the dispose invalid-free that killed
migrate at 4.5 s / 1.18 GB is GONE — the step now runs the full 47 MB
emit-C roundtrip parse+translate. BUT the memory wall stands:
`WITH_MEMORY_LIMIT_BYTES=118111600640 /usr/bin/time -l
/tmp/flip-stage2-probe migrate out/emit-c-roundtrip/main.c -o <out.w>
-I runtime -include out/gen/wl_decls.h --no-c-export` dies CLEANLY at
the cap: "memory limit exceeded: committed=118111558320" (110 GiB
committed), peak memory footprint 102,152,184,096 B (95.1 GiB), max
RSS 35.6 GB, 8650 s wall (2858 user / 5764 sys — the box was
swap-bound; committed-bytes is pressure-independent, so the 110 GiB
allocation volume is real). Verdict: #747's flip alone does NOT fix
the D28 transient-retention blow-up (old wall 94.4 GiB OS-kill,
new 110 GiB cap-kill — same class). The un-pin (ef25dd52) can stay:
the limiter now fails loudly instead of the OS kill. Next lever is
the D28 bridge-retention work itself, or profiling the migrate
child's allocation sites (the session_strdup i64-counter fix's
un-indexed-lookup family notes at handoff "Roundtrip attempt 2" still
apply). Note the fs-cache instance-I UAF did NOT fire in migrate
(different path — no Frontend fs-cache store).

INSTANCE I (NOT fixed; next mechanical wall) — deps-manifest UAF.
Symptom: probe `check` of a c_import test dies rc=139 (EXC_BAD_ACCESS
in with_str_byte_at) or "str to C string conversion: interior NUL
byte", both under c_import_fs_cache_store -> c_import_build_deps_manifest
-> cimport_deps_sorted_unique_paths(c_import_included_files())
(Frontend.w:654/566/529; also the 337 lookup consumers on warm cache).
The payload of g_cimport_included_files (the newline-joined inclusion
list, ~10.7 KB for an SDK header) is gone by the time the SECOND
consumer walks it.

Synchronous-stop-proven facts (single lldb layouts; env-width trap
protocol; addresses are per-layout):
1. with_cimport_included_files returns [X, 10710]; at that finish-stop
   X is mapped, has correct path content, a valid rt large header
   (0x29e0 = align(10711)), and IS recorded in rt_large_range_starts
   (read in-run). CImport.w:601 assignment stores exactly [X, len]
   into the global; a watchpoint shows NO further header writes.
2. A conditioned `munmap` bp armed from that stop NEVER fires covering
   X_base before:
3. a later with_alloc (origin=1) RETURNS X (trap-alloc panic bt:
   session_strdup <- translate_type_recursive_mode <-
   with_cimport_struct_field_type_translated <- ci_is_directly_demoted
   <- ci_collect_demoted_types), header at X_base UNCHANGED 0x29e0
   (indistinguishable from a fresh large alloc of exactly 10711 B,
   i.e. c_strdup of a 10710-byte C string); freelist heads and
   slab_ptr sane at that stop (read in-run);
4. then with_free (session_strdup grow, bt in-run) frees X -> large ->
   rt_munmap(X_base, 0x29f0) (caught by conditioned bp in a sibling
   layout) -> consumers fault / read scribble.
5. WITH_ALLOC_NO_REUSE=1 makes the whole family PASS (reuse-dependent),
   with NO double-free report (so the enabler is a UAF write/read into
   a freed-and-recycled block, not a plain double free).
6. HOME= (fs-cache dir empty => single consumption of
   c_import_included_files) also makes 6/7 pass; fresh-vs-poisoned
   cache does NOT matter (purged cache still crashes; cache restored
   after the experiment).

Eliminated by running (do not re-chase): bare-global return tail
(fn f() -> str: g), the `let out = g; g = ""; out` swap, slice->push->
vec-drop, and the VERBATIM cimport_deps_sorted_unique_paths fed by a
global-tail return — all CLEAN under the probe with runtime-built
payloads (mimic_global_ret3/mimic_slice_push/mimic_combo3.w in the
session scratchpad; first mimic invalidated itself via comptime-folded
static payloads — build test payloads at runtime).

Open contradiction for next session (the exact robbing line is NOT
named): X is rt-recorded at finish yet NO trap-alloc ever fired for
its creation, and the step-3 alloc returns a VA the kernel should
consider live. Two candidate blind spots: (a) an unmap path invisible
to both rt_munmap and the libc `munmap` symbol (macOS
mach_vm_deallocate — bp that next, conditioned on covering X_base);
(b) a stale rt_large_range entry + heap-shape UAF in the translation
loop (ci_collect_demoted_types / ci_translate_function churn) — the
brief's class (a)-(d) greps of the session/type-translation caches
(DeclCache name/type_spelling, g_emitted_names, translate buffers)
are the next hunt. Trap protocol notes that held: lldb print ordering
of inferior stderr vs command echoes LIES — only synchronous stops
(bp/panic/finish) order events; bp-set and env-var-COUNT changes shift
the heap (equal-width value swaps do not); learn addresses under the
final bp set.

WHAT REMAINS for #747 (delta from 04k):
- Instance I (above) — 9-10 corpus files; fs-cache path only.
- Migrate memory wall (110 GiB committed) — D28 retention, not a
  flip crash; needs its own campaign.
- Visibility family, struct_field_type_frozen (31), comptime family
  (25), lib/std de-Copy leftovers, pre_d_build_runner.w:38 — unchanged
  from 04k.
- issue59_demo_* x5: test-source fix (BindEntry Copy w/ str field) or
  the de-Copy tail design (Eric's).
- Eric's reserved: merge; print/eprint+JsonView; save/restore review.

## SESSION-RESUME (2026-08-04k, SUPERSEDED by 04l above): #747 INSTANCE G FIXED (emit-obj module filter) + THE CANONICAL OBJECT-LEVEL FIXPOINT NOW PASSES; corpus swept+classified; migrate cap un-pinned (smoke blocked by a c_import invalid-free); move-audit clean; drop-audit 15 red cells = ONE visibility family

MAIN LINE: healthy (docs-only commit here). Worktree recipe unchanged.

#747 STATE: branch `747-flip` @ ef25dd52 (two commits this session:
c7bad93c instance G, ef25dd52 migrate un-pin; tree clean; seed gate
rc=0 166.9s on the exact committed content). stage1 rebuilt;
/tmp/flip-stage2-probe rebuilt (rc=0, 135.9s, 65.9 GB peak,
106,962,752 B). Census rc=0 74.4s **48.5 GB** — 04j's favorable
31.8 GB did NOT reproduce (back at the 04i level; unexplained, not
chased). 5/5 behavior run-smoke repeated with the new probe.

FIX 7 (c7bad93c, instance G) — exactly the predicted robbed-str-family,
one line: CodegenTraits.w sync_decl_context did
`self.sema.current_module_path = self.current_decl_source_file`; under
the flip that plain field read is a MOVE and reset-on-move blanked
current_decl_source_file right after it was set. Every decl then failed
current_decl_is_imported_module_symbol() (len==0 -> "root"), so
--emit-obj emitted definitions for the WHOLE program, and
module_link_name_for_path skipped the __with_mod_ prefix on the blank
path — one robbed place, both symptoms. Fix: with_str_clone_ref (sema
retains an independent copy; the codegen field stays the live owner).
Mechanism proven in isolation (mimic program: seed keeps the field, flip
blanks it), then by verdict flip: two-module repro --emit-obj went
263 defined syms (whole program, unprefixed) -> 8 syms, byte-for-byte
the seed's symbol table.

FIXPOINT — BOTH BARS, with the G fix in:
- CANONICAL (the `:fixpoint` mechanism, build_graph_compare_files
  byte-equality over `--emit-obj -O1` objects, src/BuildGraphOps.w:20):
  stage1-emitted vs probe(stage2)-emitted objects of src/main.w are
  **byte-identical** — 1,355,736 B, 2,290 defined syms, SHA-256
  5751e9b04f879f712105eee21810c3f0e5dfb677b75ed8fd003558c80adb9b17.
  04j had this compare UNUSABLE (23 MB vs 1.36 MB objects); it is now a
  usable gate again.
- Full-binary re-run (04j method, same -o path sequentially):
  bit-identical, 106,962,592 B, SHA-256
  27a5df02754b0dd234b58b79370b77a9e92484425ee61af9373bb7ca991aafa2.

CORPUS SWEEP (probe `check` per file; baseline = main seed; verdict
diff = real fallout):
- test/behavior: 937 files — probe 776 pass/161 fail; seed 913/24;
  **137 verdict diffs**. test/spec: 210 files — probe 186/24; seed
  206/4; **20 diffs**. 157 total, classified (tools in scratchpad:
  sweep_check.w / compare_sweeps.w / classify_diffs.w):
  - 44x invalid free "pointer is not an allocated payload start" — the
    probe PANICS while checking c_import/FFI tests. lldb: with_free <-
    with_cimport_dispose (ClangBridge.w:1262) <-
    cimport_collect_macros_from_libclang (ClangBridge.w:2258) <-
    with_cimport_parse_macros. Compiler bug, flip-only, ONE family.
  - 31x rc=134 abort "BUG: struct_field_type_frozen generic-inst field
    type miss [SemaCheck.w:10530]" — generic-struct field types
    (Box/StateBox/Cell/Wrapper shapes). Compiler bug family.
  - 25x comptime regressions ("method 'push'/'insert'/'call'/'len' is
    not comptime-evaluable yet", step limit, no match arm) — ComptimeEval
    lost capability under the flip; family, not per-test.
  - 17x use-of-moved: 8x = ONE test-lib line
    (test/behavior/lib/pre_d_build_runner.w:38 `return staged_stage2`),
    5x = embedded std/compiler.w:89, 4 singles. Test-source/lib fallout;
    correct diagnostics under the new semantics.
  - 8x "symbol 'X' is not visible from this module" — see drop-audit
    below; MINIMAL REPRO EXISTS.
  - Misc (~32): 5x K-inference 'str' vs '&str' (std/collections.w:97),
    4x+ Package cannot-implement-Copy (std/build.w:259 — the known
    lib/std de-Copy leftover), D22 §13.6 ownership-through-borrow in
    test sources (correct), &T-vs-T arg mismatches, singles.
  NOT fixed per brief; classes + counts recorded for the tail work.

MIGRATE (D28 cap): un-pinned in ef25dd52 (emit_c.w back to plain
emitc_run_capture, per D28 ruling 3's own REVERT note). Smoke BLOCKED —
no RSS gold number: `/tmp/flip-stage2-probe migrate
out/emit-c-roundtrip/main.c -I runtime -include out/gen/wl_decls.h
--no-c-export` dies at 4.5s / 1.18 GB RSS with the SAME
with_cimport_dispose invalid-free as the 44 corpus files (migrate parses
C through the same session). Fix that family and the roundtrip's
94.4 GiB question answers itself.

AUDITS (candidate=/tmp/flip-stage2-probe, baseline=/Users/eric/with/
src/main; harness = MAIN repo's tools — the WORKTREE copies of
move_audit.w/drop_audit.w do not compile under the probe (classify's
consuming-str params + looped call sites; needs the campaign's &str
wrapper treatment — mechanical, not done)):
- move-audit: 15 cells, 0 vs-expected FAIL, 0 vs-baseline DIFF. GREEN,
  including both [FLIPPED:#691] vec cells.
- drop-audit: 115 cells, 15 REGRESSION vs baseline — ALL are candidate
  COMPILE-FAILs of the visibility family above, on box/rc shapes
  (reassign_over, move_then_reassign, consume_cond_*, consume_call,
  field_take x boxbare/rcbare/boxfield). Drop scheduling itself is NOT
  indicted — those cells never reach codegen. All other 100 cells `same`.
  MINIMAL REPRO (8 lines; seed ok, probe errors):
    use std.builtins.print_i32 + use std.box; fn helper(x: i32) -> i32;
    main: let b = Box.new(41); print_i32(helper(*b.as_ref()))
    -> "error: symbol 'helper' is not visible from this module".
  Generic std import (Box/Rc/sync) robs the checker's module identity —
  smells like sema.current_module_path save/restore blanking (the
  SemaCheck/MirLower/ComptimeEval save/set/restore sites), which is
  EXACTLY the save/restore ruling review reserved for Eric. Also
  plausibly adjacent to the struct_field_type_frozen and comptime
  families (all generic-instantiation-shaped); not verified, do not
  assume.

WHAT REMAINS for #747:
- ERIC'S (untouched per brief): merge decision; de-Copy tail design
  (print/eprint consuming str, JsonView); save/restore ruling review.
- c_import invalid-free family (44 corpus + migrate blocker) — next
  mechanical wall, single family, lldb path recorded above.
- Visibility family (drop-audit 15 + corpus 8 + likely spec singles) —
  overlaps the save/restore review; repro above.
- struct_field_type_frozen generic-inst aborts (31); comptime family
  (25); lib/std de-Copy leftovers (build.w Package Copy, collections.w
  K-inference, string.w:109, compiler.w:89); test-source fixes incl.
  the ONE pre_d_build_runner.w:38 line (clears 8 files).
- Worktree tools/move_audit.w+drop_audit.w &str adaptation.
- Then: full battery ALONE on the merge (ownership-semantics isolation
  rule) + :move-audit/:drop-audit via the build targets, then reseed.

## SESSION-RESUME (2026-08-04j, SUPERSEDED by 04k above): #747 INSTANCE F FIXED + THE FLIP HAS REACHED FIXPOINT (bit-identical stage1-built vs stage2-built binaries); -e/run/build all rc=0; 5/5 behavior smoke

MAIN LINE: healthy (docs-only commit here). Worktree recipe unchanged.

#747 STATE: branch `747-flip` @ 1777e5ef (one commit this session, tree
clean, seed gate rc=0 153.7s). stage1 rebuilt; /tmp/flip-stage2-probe
rebuilt (rc=0, 127.0s, 66.8 GB peak, 107,011,536 B);
/tmp/flip-stage3-probe rebuilt by the fixed stage2 (rc=0 — this exact
command exited 1 before the fix — 125.6s, 13.2 GB). Census rc=0 75.3s
31.8 GB (down from 48.35 GB; not investigated, favorable). Honest
self-check `WITH_MEMORY_LIMIT_BYTES=118111600640 /tmp/flip-stage2-probe
check src/main.w`: rc=0, 73.0s, 428.5 MB peak, positive phase evidence
(parse 751 decls, frontend.sema 42.2s decls=9244, sema types=10054,
mir.lower 20.5s bodies=7150).

FIX 6 (1777e5ef, instance F) — consuming a whole base materializes its
live str views into owned captures. Compilation.execute_binary_link_plan
(src/compiler/Compilation.w:938): `let bin_path = plan.bin_path` is a
view; the next call consumes `plan` by value; reset-on-move blanks the
base storage and the tail read returned "" after a successful link, so
every -e/run/build exited 1 with working artifacts. General mechanism in
MirLower (NOT a Compilation.w spot edit):
`materialize_str_views_of_consumed_base(local_id)` — called from
consume_moved_operand's plain-local branch and (pre-drop, since the drop
statement precedes the consume there) from lower_drop_glue_and_consume.
For each live same-scope alias whose place is a pure field path rooted at
the consumed base and whose binding type is str: new owned local bound to
the same name, StorageLive, `RK_STR_CONCAT_N([copy field, ""], 2,
move_first=0)` — a 1-part concat is a codegen PASS-THROUGH (shallow), so
the "" second part forces str_concat_n_copy = an independent owner;
guarded DK_VALUE drop; alias entry dead-named. Unlike fix 2 the consumer
OWNS the base (callee drops it), so the capture must CLONE, not transfer
— a shallow copy + drop would double-free, a copy without drop would
dangle. RESIDUE (deliberate): non-str view types and cross-scope
consumes keep the robbed-view behavior (same-scope-only for the same
re-execution reason as fix 2's residue).

VERIFIED: repro_basecons.w (scratchpad) pre-fix 13/0/<empty>, post-fix
13/11/hello-world, debug-alloc 0 leaks 0 double-frees (callee saw full
values AND the view kept its value). repro_basecons_drop.w (explicit
drop(x) with live view): correct, 0 leaks. repro_saverestore_call /
repro_stamp / repro_sr5 unchanged vs 04i expectations (sr5's 10 leaks =
9x pre-existing (b) f-string-in-loop + 1x (a) var-c-fields; sr5 has no
whole-base consume — not a regression). Probe acceptance: `-e
'print_i32(42)'` -> 42 rc=0; `run` rc=0; `build` rc=0 + binary runs.

FIXPOINT — REACHED, and stronger than the normalized bar:
- Canonical mechanism (build.w `:fixpoint`): byte-compare of `--emit-obj
  -O1` objects (build_graph_compare_files, src/BuildGraphOps.w:20);
  normalization = objects have no UUID/signature.
- Definitive compare run instead at full-binary strength: stage1 and the
  fixed stage2 each built `src/main.w -O1` to the SAME output path
  (/tmp/fpx/with, sequentially). Result: **bit-for-bit identical**,
  107,011,376 B, `cmp -l` = 0 differing bytes (even LC_UUID and the
  ad-hoc signature reproduce), SHA-256
  fcfd2bea47f2a7638f0beb106b6998ab18105d300186baf68b584ea521b6af0a.
- The differently-named probes (107,011,536 B; stage2
  63124f94deac62167d7fee04ecbfd20a919fc670e81947ce2d0516c7388a74d4,
  stage3 f986f229b12a3988292f90d486629893e7463f004e0c52e82eafab6db69de577)
  differ in exactly 89 bytes, all classified: 8 LC_UUID + 16 embedded
  output-path digit chars ('2'->'3' in N_OSO stabs from the differing -o
  names) + 65 code-signature bytes over those pages; 0 unexplained.

INSTANCE G — NAMED, NOT CHASED (out of fixpoint scope, no fix per brief):
the canonical object-level compare itself is unusable because `--emit-obj`
(module_object_mode) DIVERGES BEHAVIORALLY: seed-built stage1 emits the
root-module-only object (1,355,736 B, 2,290 defined syms, __with_mod_*
prefixed — matching main's Copy-world compiler), while the flip-built
stage2 emits a whole-program object (23,081,728 B, 50,843 defined syms,
Lexer/drop-glue included). Same source both sides => the flip-BUILT
binary misbehaves on the module-object filter path — smells like the
robbed/blanked-str family (module path comparisons in
Backend/CodegenUnits filtering). Value-only; the build path is
unaffected (bit-identical above). Root-cause when the de-Copy tail is
worked.

SMOKE: stage3-probe as a compiler: -e 42 rc=0, run rc=0, check rc=0.
Flipped stage2 on test/behavior/: behav_arithmetic, behav_vec_is_empty,
behav_match_unit_pattern, behav_str_large_literal, behav_veciter_iter_sum
— 5/5 pass (outputs match //! expect-stdout).

WHAT REMAINS for #747:
- De-Copy tail: print/eprint consuming str (a `print(s); s.len()` is a
  move error today — design question for Eric) + the JsonView question;
  see D22/D27 notes.
- Instance G (emit-obj module filter, above) + the also-observed 04i
  issues (a) var-c mut-receiver Maybe drop state, (b) f-string loop temp
  leaks, (c) document the rt trap hook in docs/debug-allocator.md.
- Corpus sweep; un-pin the emitc_migrate cap.
- :move-audit / :drop-audit, then the full battery ALONE on the merge
  (ownership-semantics isolation rule), then reseed.

## SESSION-RESUME (2026-08-04i, SUPERSEDED by 04j above): #747 SELF-CHECK GREEN (rc=0, 68.9s, 428 MB!) + STAGE3 BUILT AND WORKING; instances C/D/E fixed; LAST KNOWN WALL: instance F (link-plan path view robbed by base consume) — value-only, binaries work

MAIN LINE: healthy (docs-only commit here). Worktree recipe unchanged.

#747 STATE: branch `747-flip` @ 2bceaa86 (4 commits this session, tree
clean, final seed gate rc=0 153.7s on the committed tree). stage1
rebuilt 4x; /tmp/flip-stage2-probe current (rc=0, 128-134s, ~66 GB
peak, 106,978,768 B). Census: rc=0, 70.9s, 48.35 GB.

THE HONEST SELF-CHECK PASSED (first flipped-built compiler self-check):
`WITH_MEMORY_LIMIT_BYTES=118111600640 /tmp/flip-stage2-probe check
src/main.w` -> rc=0, 68.9s wall, **428 MB peak RSS**. NOT false-green:
WITH_PROFILE shows every phase with positive evidence — parse 751
decls, resolve 1.57s, comptime 5.4s, frontend.sema 39.8s decls=9243,
sema 2.5s types=10052, mir.lower 19.0s bodies=7149, validate, async.
The 48 GB the seed-built stage1 needs for the same check is seed-leak
behavior; the flip compiler actually frees — 112x memory reduction is
the flip paying off, not skipped work.

STAGE3 BUILT: `/tmp/flip-stage2-probe build src/main.w -O1 -o
/tmp/flip-stage3-probe` wrote a 106,978,768 B binary (same size as
stage2; raw cmp differs at char 2028 = Mach-O header region, likely
LC_UUID — run a real `:fixpoint`-style normalized compare next).
123.5s, 13.7 GB peak. Exit rc=1 is instance F's FALSE FAIL (below) —
the artifact is good: stage3 `check` rc=0, stage3-built tiny binary
prints and exits 0. Both probes smoke: check tiny ok; built binaries
run. `-e`/`run`/`build` still exit 1 (instance F, value-only).

FIX 3 (97146391, instance C) — identical-place copy assignment is a
no-op: the restore half of `let saved = self.f; <callee reassigns
self.f>; self.f = saved` lowers its RHS through the alias as `copy
self.f`. finish_assignment_to_place emitted drop-before-overwrite plus
the 03h cap-local whose scheduled drop freed the payload the field
still owned -> dangling field -> next overwrite freed the recycled
block. In the probe that block had become fn_may_alloc's occ array
(installed by the 16->32 grow), so the 32->64 grow hit `invalid free`
under check_fn_body_with_sig_at. Instrumented trap-hook bisect
(free-hit predicate: [handle+0x10] == occ addr, k*=14) pinned the
freeing site: the per-body epilogue restore of current_module_path
(SemaCheck.w:2348, Sema field +0x2138; -O1 load-forwarding makes the
cap-drop read the field directly in disasm). Fix in
MirLower.finish_assignment_to_place: extend the `x = move x`
identical-place no-op to OK_COPY (never drop/materialize/store), plus
SemaCheck source fix: capture module path by `move` (like
save_label_registry) so the restore is value-correct.
NOTE the semantics ruling implied: `self.f = saved` where saved is a
live VIEW of self.f is a NO-OP (a binding names what's there, AT USE
TIME). Capture-intent must be spelled `move`/clone. Other save/restore
idioms of this shape in the tree keep no-op restores (memory-safe,
value = callee's last write) — grep candidates before relying on one.

FIX 4 (35fe609d, instance D) — observer probe args must not re-deref a
consumed contextual-copy adjustment: lower_observer_probe_arg
(MAP_GET/MAP_CONTAINS/VEC_CONTAINS keys, str reader needles) saw
TY_REF and lowered materialize-then-deref; when Sema recorded a D22
contextual-copy adjustment, lower_expr already yields the deref'd
owned key value, so the helper deref'd the VALUE (MIR: `_50: &i32 =
copy _49.*; ... copy _50.*`). First victim past C:
stamp_move_site_liveness segfaulted dereferencing a sym id (0x12) on
binding_last_use.contains(root), root = &i32 element view of
consume_call_sites. Guard mirrors the f-string ref path's existing
adjustment check. Standalone repro: repro_stamp.w (scratchpad).

FIX 5 (2bceaa86, instance E) — `var actual_source =
actual_options.source_path` in run_build_command is a flip TRANSFER
(reset); the explicit-source branch never wrote the field back ->
every `with build file.w` compiled with source_path == "" ("cannot
open ''"). Restore the field at branch end, mirroring the
empty-source arm.

INSTANCE F — NAMED, NOT FIXED (budget: C + two more spent):
Compilation.execute_binary_link_plan (src/compiler/Compilation.w:938):
`let bin_path = plan.bin_path` binds a VIEW of the param field; the
next line passes `plan` BY VALUE into
compilation_execute_binary_link_plan (whole-base consume -> reset);
the tail `bin_path` re-reads the reset storage and returns "" AFTER A
SUCCESSFUL LINK. Every -e/run/build exits 1 while writing a working
binary. Class: live view of a field place whose BASE local is consumed
by a later call — the cross-statement sibling of fixes 1/2. Fix
direction: when a whole base local is consumed
(consume_moved_operand on a struct-typed arg), materialize live
aliases of its field places into owned locals first — fix 2's
cap-local machinery, triggered at base-consume instead of
place-assign. (Or classify such field reads as OK_MOVE at binding when
the base is later consumed, like fix 1.)

ALSO OBSERVED (file issues when back on main): (a) `var c` in main
passed as mut-receiver leaves drop state Maybe -> struct fields never
dropped at main exit (1 leak per repro run, pre-existing); (b)
f-string temps inside a for-loop leak (repro_sr5.w, 3 leaks); (c) the
rt trap hook (2753858c) is a permanent debug-alloc extension —
document in docs/debug-allocator.md when it next gets touched.

VERIFIED THIS SESSION:
- repro_saverestore_call/sr2/sr4/sr5/sr6.w: pre-fix corruption or
  wrong-value+cap-drop; post-fix consistent view semantics, debug-alloc
  0 double-frees (the 1 leak = pre-existing (a) above).
- repro_stamp.w: pre-fix rc=139; post-fix correct output rc=0.
- stage2 -e/check/build under WITH_DEBUG_ALLOC: zero
  double-free/invalid-free reports end to end.
- census 70.9s/48.35 GB rc=0; self-check + stage3 as above.

TRAP-HOOK PROTOCOL (what actually worked for C): learn the doomed
address under lldb (same-bp-set replay; {with_panic_core} only), then
env-only iterations — WITH_DEBUG_ALLOC_TRAP_FREE=<addr, zero-padded
12> prints that block's whole alloc/free life with origins;
TRAP_FREE_HIT/TRAP_ALLOC_HIT=<n, padded 4> panic on the n-th event for
a bt or a thread-return-resume plant point. Env VALUE changes of equal
width do NOT shift the heap; adding/removing a bp or a CONDITIONED bp
DOES (a conditioned hm_grow bp shifted everything — learn addresses
under the final bp set). `frame select 1` before `thread return` (the
inlined-frame refusal). Watchpoints planted mid-run work (W3b/W4) but
planted too early they silently never fire (W6) — prefer the hook's
panic-at-hit + free-hit bisect on a place-content predicate; it needs
no wp at all.

## SESSION-RESUME (2026-08-03h, SUPERSEDED by 04i above): #747 TWO view-ownership classes FIXED (comptime transform + trait-default check run clean); NEXT WALL: fn_may_alloc handle freed-while-live via a str/raw-path free

MAIN LINE: healthy (docs-only commit here). Worktree recipe unchanged.

#747 STATE: branch `747-flip` @ 5aa97340 (two commits this session, each
seed-gated rc=0, stage1 walls 154s/156s). stage1 rebuilt twice;
/tmp/flip-stage2-probe rebuilt twice (rc=0, 135.8s, 68.0 GB peak,
107,009,376 B). Census after both fixes: ok, rc=0, 75.0s, 48.35 GB.

FIX 1 (72c609e1) — view reads from frame-owned dropping storage are
TRANSFERS: comptime_eval_finish (src/ComptimeEval.w:1115) drains the
consumed evaluator through let-bindings; lower_binding_alias_place made
them views of the param's field places and lower_var's alias branch
lowered every use as bare OK_COPY. MIR (sym7851): `_1.* = copy _2.f924`
+ aggregate `copy _2.f7697/f7714/f1318/f1319` + whole `drop(_2)` — two
owners per drained field; the evaluator drop freed Sema's hashmap
tables, the next ct_eval_truthy freed them again (128 B DOUBLE FREE,
bt: with_hashmap_free <- __drop_struct_365 <- comptime_eval_finish).
Fix in MirLower.lower_var alias branch: pure field path + base local
with a scheduled VALUE drop + drop-needing type => OK_MOVE (consumers
run consume_moved_operand: static exclusion + reset-on-move). Borrowed
bases (mut-fn receiver, share params) keep the pure view — lex_ident's
`let src = self.source` unaffected. Post-fix MIR: moves + zst resets,
drop(_2) collapsed to residual drop(_2.f642).

FIX 2 (5aa97340) — a view binding takes ownership when its place is
reassigned: check_trait_default_method_body_for_impl (SemaCheck.w:2380/
2388/2424) does `let saved_assoc = self.assoc_type_bindings;
self.assoc_type_bindings = fresh; ...; self.assoc_type_bindings =
saved_assoc` (same class: saved_subst_syms/tys Vecs). The let is a VIEW
of the field place, so the overwrite's drop-before-overwrite freed the
saved handle AND the restore re-read the CURRENT value through the
alias (restored fresh onto itself). lldb free-trace (same-bp-set layout
replay): one handle freed 5x — prepare_comptime_eval_copy inlined
(+416/+464) then ctm epilogue field drops at Sema offsets 7464 and 7352
(x27=sp+0x4B98), identical headers, no alloc between = true two-field
alias. Fix in MirLower.finish_assignment_to_place: before the
overwrite drop, each LIVE same-scope view binding aliasing exactly the
assigned place is materialized into an owned local bound to the same
name (StorageLive + copy + guarded DK_VALUE drop), the alias entry is
dead-named, the overwrite drop is skipped. The later `self.f = saved`
resolves to the owned local and MOVES it back via fix 1's rule.
Repro: pre-fix 2/1/0/panic; post-fix 2/1/2/6, debug-alloc leak 0.
RESIDUE: a binding in an OUTER scope whose place is reassigned inside
a loop/branch keeps the old drop-before-overwrite (the capture stmt
would re-execute per iteration and clobber the saved value) — cross-
scope instances of the idiom are still the pre-fix class.

VERIFIED THIS SESSION:
- repro_finish.w (consumed carrier drain -> raw-ptr store + returned
  struct): pre-fix DOUBLE FREE 32 B origin=Vec; post-fix correct
  output (4 leaks = the repro's own raw-store abandonment of the old
  pointee — §16.11 raw-store semantics, not a fix defect).
- repro_saverestore.w: above.
- stage2 now gets THROUGH comptime transform and trait-default checks
  into Sema.check_bodies (previous wall was the first ct_eval_truthy).

NEXT WALL (instance C — evidence pinned, NOT root-caused; the two-fix
budget for this session was spent):
- stage2 -e/check panic: invalid free in hm_grow <- with_hashmap_insert
  <- Sema.check_fn_body_with_sig_at <- check_bodies. The insert is
  `self.fn_may_alloc.insert(fn_name, 0/1)` (SemaCheck.w:2297-2300;
  disasm: map at Sema offset 0xc68, flag at 0x1ef4). Debug-alloc:
  DOUBLE FREE size=32 origin=Vec first_drop=__drop_struct_93 (= Vec
  glue label) — hm_grow's free of "old keys" read through a STALE
  handle hit a block last legally owned as a Vec buffer.
- The fn_may_alloc HANDLE block itself was recycled while live: at the
  report stop, [x19+0xc68] (frame 8) = a block that earlier appears as
  the VALS array of a DIFFERENT map freed in the merge loop
  (Zcu/Frontend merge_resolved_modules_frontend). Traced ALL
  with_hashmap_free + with_vec_free + with_vec_free_drop_origin calls
  (16,277 events, same-bp-set replay): the handle is NEVER an x0 of
  any of them => the first wrong free of that block came from the
  str-free or raw rt_free space (with_str_free untraced — too many
  hits for per-hit lldb logging; needs a targeted approach: condition
  a str-free bp on the address learned from a first same-bp-set run,
  or add a temporary rt-side trap-on-address env hook).
- merge_resolved_modules_frontend MIR (sym14434) itself looks clean:
  parser fields moved/reset correctly, per-module residual drops are
  the parser-owned 8 (tokens/source/6 Vecs), pool/ast/intern types are
  drop-excluded, `_0 = copy _4` return. The cascade root is upstream
  of the fn_may_alloc symptom.
- FALSE-GREEN reminder from 03f still applies: stage2 `check
  src/main.w rc=0` is only real with ~48 GB peak + all WITH_PROFILE
  phases (the 8f66f566 gate now enforces positive sema evidence).
  Self-check NOT attempted this session (blocked on instance C);
  stage3 not attempted.

LLDB PROTOCOL NOTES (add to 03f traps): on this box's lldb, multiple
`--one-liner` flags on `breakpoint command add` keep ONLY THE LAST —
use the multi-line DONE-block form in a `-s` script file. Same-bp-set
runs replay heap addresses exactly (verified twice); ANY bp-set change
shifts them. `process launch -X false -- args` avoids the argdumper
shell-expansion failure. Guarded field drops pair as: `mov w8,#OFF ;
add x0,x27,w8 ; bl rt_value_is_zero ; cbnz -> skip ; ldr x0,[sp,#S] ;
bl <free>` with x27 = sp + const — the guard word IS the freed word.

## SESSION-RESUME (2026-08-03f, SUPERSEDED by 03h above): #747 STR_SLICE view-drop ROOT-CAUSED+FIXED (stage2 parses whole modules); NEXT WALL: fn_meta_map table freed-while-live + a FALSE-GREEN check exit

MAIN LINE: healthy (docs-only commit here). Worktree recipe unchanged.

#747 STATE: branch `747-flip` @ ef0e9422 (one commit this session,
seed-gated rc=0 158s). stage1 rebuilt; /tmp/flip-stage2-probe rebuilt
(rc=0, 57.9 GB peak). Census: rc=0, 48.34 GB (unchanged).

ROOT CAUSE #1 (fixed, ef0e9422): src/CodegenDispatch.w STR_SLICE
intrinsic (was ~:9236) emitted the Copy-world ZERO-COPY VIEW
(gep recv.ptr+start, sub end-start, build_str_value) while flip MIR
types slice results OWNED and schedules drop(text). Dropping the view
freed a pointer INTO the receiver's live buffer; start=0 frees the
receiver's own block. Full instruction-level chain in the OLD probe:
Lexer.lex_ident `let text = src.slice(start, pos)` freed the lexer's
SOURCE payload on the first ident token (with_str_free_drop_origin
inlined in lex_ident; `let src` itself was correctly alias-bound — the
1fca9200 fix held); the tags Vec's first grow freelist-popped the same
block (prelude: break after push 1 = first 16B-class alloc; tiny.w:
after push 9 = the 8->16 realloc); the lexer then lexed ITS OWN TAG
BYTES as source — every hallucinated tag matched byte-for-byte (tag 10
int-bytes read as '\n' -> NEWLINE, 108 as 'l' -> IDENT, 62 as '>' ->
TK_GT). bddbda6f's rt-side slice copy never applied on this path —
the intrinsic bypasses rt. Fix: lower STR_SLICE through with_str_slice
(alloc_str copy), same shape as STR_BYTE_AT. Only other raw
build_str_value sites: FIXED_STRING_AS_VIEW (owned-typed view of an
inline buffer — free is a no-op via is_owned, but same doctrinal
family; see review items) and two empty-str constants (safe).

03e CORRECTION: the "TokenList blanked {0,0,0,4}" reading was the
RECYCLED tags buffer state, not a blank struct — in this session's
lldb runs the TokenList headers arrived INTACT at parse_module (ptr/
len/cap/elem all correct); the CONTENT was garbage. init_with_pool,
Parser.init, and the csfm caller all marshal tokens correctly at the
machine level (verified store-by-store in disasm). The struct-literal/
return/store chain was NEVER the bug.

VERIFIED THIS SESSION:
- repro_slice.w (slice-drop shape) + repro_v3/v4 (Parser-shaped byval/
  literal/return chains): correct output, --debug-alloc leak 0 under
  the fixed stage1.
- with_vec_get_str is NOT in the stage2 binary (nm: only
  with_vec_get_ptr) — the flagged alias-return is unreachable; no fix
  needed there for stage3.
- New stage2 smoke: --version ok; parse now WORKS (WITH_PROFILE shows
  751 decls parsed from src/main.w; imported std modules parse past
  the old wall).

NEXT WALL (evidence recorded, NOT root-caused):
1. Remaining premature-free instance(s), prelude/std path only:
   `-e` panics invalid free (plain) / debug-alloc reports DOUBLE FREE
   size=64 origin=Vec; detection bt both modes: hm_grow freeing
   AstPool.fn_meta_map's old table during add_fn_meta <-
   Parser.parse_extern_decl <- parse_module <- resolve_from_root
   (module loop). `check tiny.w` crashes rc=139 at TokenList.get_start
   (starts.ptr into unmapped page) inside the SAME resolve-loop module
   parses. WITH_DEBUG_ALLOC=1 masks the tiny.w crash (alloc-pattern
   dependent). A 9-hit free trace of one 64B block is in the session
   log: the suspicious free is a with_str_free of stack slot sp+0x30
   in parse_module (right before add_decl, MIR drop(_109) region =
   parser_active_arch() result which should be RODATA — suspect LLVM
   stack-slot coalescing + our unconditional drop emission freeing a
   slot whose live occupant is a different str, or another view-typed-
   owned producer). parse_module MIR has exactly three drops: _1.f707,
   _109, _1.f704 — start there.
2. FALSE-GREEN TRAP — do NOT trust `check src/main.w rc=0` from the
   stage2 probe: it "passes" in 0.09s/16MB because the pipeline
   SILENTLY STOPS after frontend.parse (WITH_PROFILE shows no resolve/
   sema lines; corrupted diagnostics path truncates and still exits
   0). A real gate must show ~48GB/70s+ and all profile phases. The
   self-check gate is NOT passed; stage3 not attempted.

TRAPS this session: lldb bp/wp addresses drift BETWEEN runs when the
breakpoint set changes (heap layout) — never carry a literal address
across runs; verify in-session. Conditions with C casts
('*(unsigned long*)$x0') can fail evaluation SILENTLY = no stops;
plain $-register conditions are safe. Watchpoint reports a phantom
first hit at creation. Batch lldb: nested DONE blocks break; use
run-then-add-watchpoint two-stage scripts. Debug-info filenames all
collapse to main.w with PER-ORIGINAL-FILE line numbers, and inline
frame names can be flat-out wrong ("todo", "regex_expand_replacement"
in parse paths) — trust only symbol names + MIR + disasm.

REVIEW ITEMS FOR ERIC (adds to 03e list):
- STR_SLICE now always copies (perf cost on every slice until #748
  view tokens land) — same interim-copy policy as bddbda6f rt fns.
- FixedString.as_view returns ty_str (owned-typed view of the inline
  buffer, SemaCheck ~:18247); drop is a no-op only because is_owned
  rejects non-heap pointers. Same owned-alias family; wants a view
  type under #748.
- Seed bug (pre-flip, installed compiler): str.find(needle) through a
  &str PARAM returns -1 while the same call on an owned local works
  (repro: findtest2.w pattern). Worth an issue after the flip lands.

## SESSION-RESUME (2026-08-03e, SUPERSEDED by 03f above): #747 extern-arg class CLOSED (observer semantics end-to-end); stage2 lexes+parses; NEXT WALL: TokenList blanked through Parser.init struct literal

MAIN LINE: healthy, untouched (docs-only commit here). Before ANY
reseed: probe candidate as ORCHESTRATOR (#757).

#747 STATE: branch `747-flip` @ c0f1fa61 (7 commits this session, every
one seed-gated rc=0: bddbda6f rt owned-copy returns, 94df7c03 extern
bit-copy + intrinsic needles, b80af0fb wl_ decls + vec_push_str effect,
696f8a4f wrap revert, ab43619c seed annotations, 1fca9200 let-of-field
alias, c0f1fa61 init_with_pool pool fix). Worktree recipe unchanged.

THE CONSUMING-EXTERN CLASS IS CLOSED — not by wraps, by ONE rule at both
layers (the HashMap 24f38e97 precedent, generalized):
- Sema.extern_param_is_bit_copy (SemaCheck.w, next to mark_moved_if_consumed):
  extern/ci callee + no DECLARED consume/escape_value effect => the param is
  a bit-copy, no ownership transfer. This was ALREADY sema's documented
  doctrine in check_call ("Extern/C params are bit-copied and do NOT own");
  the census gap was never a missing diagnostic — sema's model was borrow,
  MirLower's lowering was move. The divergence WAS the stage2 corruption.
- MirLower.lower_call_arg (callee_sym now threaded from lower_call via
  comp_resolved, redirect/arg-nodes/receiver-operand variants): a PLAIN
  OK_MOVE arg to a bit-copy extern param re-issues as a non-consuming
  OK_COPY share — caller keeps ownership + drop; rvalue args stay
  registered stmt temps (the old consume CANCELLED the temp and leaked
  every rvalue arg). Explicit `move`/`copy` keep transfer semantics.
- Str reader intrinsics (contains/starts_with/ends_with/find/index_of/
  split needle, replace args 0+1) lower through lower_observer_probe_arg
  (str_intrinsic_observer_arg helper; also the optional-chain variant).
  Sema never consumed these (only method_arg_stores_value args consume).
- rt_core.w: slice/slice_ref/substr/trim/replace/split/split_vec/lines_out
  now alloc_str-COPY their results; trim/replace/upper/lower no-op paths
  stop returning `s`. Observer args + view returns would double-free at
  offset 0 (the view IS the payload start) and dangle otherwise. #748 view
  tokens can recover the zero-copy forms.
- with_vec_push_str pinned @[effect(val: escape_value)] (vec RETAINS the
  header — the one genuinely-consuming str extern in src/lib). wl_assemble/
  compile_ir_to_object decls fixed str->&str (defs take &str; the str decl
  was a real ABI mismatch). 840476d6's ~15 CLI clone wraps REVERTED.

SECOND ROOT CAUSE, lldb-proven to the instruction: `let src = self.source`
(unannotated let of a non-Copy FIELD) compiled to ldp(load)+stp xzr,xzr
(RESET self.source)+with_str_free_drop_origin at return — a field MOVE the
checker models as a VIEW (D27 "a binding names what's there"; the census
campaign annotated every base-mutating site). skip_whitespace blanked
self.source, next_token read len 0 => instant EOF => "parser returned an
empty module" for every source. Evidence chain: tokenize-entry dump showed
source intact; next_token/TokenList.append hit count exactly 2;
parse_fn_decl/parse_use_decl/add_decl 0. FIX: lower_binding_alias_place now
resolves field-of-IDENT bases (receiver included, alias-bound names too) to
a projected field place => pure alias binding, no move/reset/drop. The
machinery predates the flip (Apr #78, NK_CALL + autoderef bases only); str
was Copy then, so the fallback byte-copied and nobody noticed.

ALSO: Parser.init_with_pool stored the moved-from `pool` in the literal
while file_pool (holding set_current_file_id) dropped at exit — freed the
caller's live prelude pool. Fixed (pool: file_pool). Checker was SILENT on
this var-rebind-then-reuse of a param: a real census gap instance to fix.

NUMBERS (all with WITH_MEMORY_LIMIT_BYTES=118111600640):
- probes (stage1-built): probe_extern (find_source_arg pattern incl.
  left-to-right slice(arg,9,arg.len())), probe_methods (receiver+needle
  survival, slice/trim/split copies), probe_concat (a,b valid after ++):
  all rc=0 correct output, --debug-alloc leak count=0 each.
- census: rc=0 "ok", ZERO diagnostics, 72-86 s, peak 48.33 GB (03d:
  76 s / 48.2 GB — the rt copies are noise at this scale).
- stage2 build: rc=0, 129-168 s, peak 63.7-65.4 GB -> /tmp/flip-stage2-probe.
- stage2 smoke: --version ok. The 03d parser-empty-module is DEAD: the
  lexer lexes (correct tags+spans in --dump-tokens) and the parser parses.

NEXT WALL (facts collected, NOT yet root-caused): the TokenList is BLANK
inside the constructed Parser.
- At Parser.init_with_pool ENTRY the tokens are INTACT: TokenList passes
  flattened in regs (x0=tags.ptr, x1=tags.len — x1 was 0x12=18 = exactly
  tiny.w's 18 tokens; second call 0xf=15 for the prelude synthetic).
- At Parser.parse_module ENTRY parser.tokens.tags = {ptr 0, len 0, cap 0,
  elem 4} — BLANKED, not dangling.
- So the loss is in init_with_pool's literal / return-by-value / the
  caller's `var pparser =` store. Same ordering genus as the let-of-field
  bug (reset-before-read of a moved slot). Disasm head of init_with_pool
  shows the spilled param regs and five with_vec_new_out(elem=4) calls for
  the literal's fresh Vec fields; the tokens stores were beyond the 80
  instrs read.
- Downstream symptoms (all one cause): peek on the null vec reads garbage
  tags => "expected import path after 'use'" hallucinations; the
  diagnostic renderer then displays RECYCLED memory (its own output bytes
  as source lines) => the freed-buffer reuse is real; `-e` panics
  "invalid free ... origin=drop#struct __drop_struct_468".
- Attack for next session: dump MIR for Parser.init_with_pool with the
  flipped stage1 (`with-stage1 check --dump-mir`/analyze select on a
  Parser-shaped repro), or reduce a tiny two-field-struct repro: With fn
  takes struct-with-Vec param byval-flattened, stores it in a literal,
  returns the literal by value — check the param slot reset ordering
  against the literal's field reads. drop-audit cell shape: (flattened
  struct param x struct literal x return-by-value).

TRAPS this session: lldb address breakpoints don't survive ASLR — use
-r regex name breakpoints (With symbols are ___wcu$NNN$Type.method; $ needs
quoting, regex is easier). --auto-continue + `breakpoint list -b` hit
counts answer "did X run and how often" without any prints. Frame-variable
info is absent (no DWARF locals) — argument registers at entry + struct
field offsets are the way. Do NOT edit worktree files while a seed gate
builds — a mid-build edit produced a phantom red gate (heap corruption in
the seed reading changing sources) that cost a re-run.

REVIEW ITEMS FOR ERIC (this session):
- extern bit-copy rule: sema doctrine now enforced in lowering; is the
  D5/G1 reading (extern str params observe unless effect-pinned) blessed?
- let-of-field alias bindings: broad semantics change for unannotated
  non-Copy field lets in flip-built code; checker already modeled it.
- rt slice/substr/trim/replace/split/lines copies: perf cost accepted
  interim (census peak unchanged); #748 recovers.
- print/eprint (lib/std/builtins.w) take consuming `str` — observer
  doctrine says they should observe; untouched (census-clean today).
- rt with_vec_get_str returns an alias of the vec element typed owned —
  same alias-return family, untouched (may be unreachable under D27
  lowering; verify before stage3).
- Checker gap: `var y = x; use(x)` on non-Copy PARAMS produced no
  use-after-move diagnostic (Parser.init_with_pool). Needs a census rule.

## SESSION-RESUME (2026-08-03d, SUPERSEDED by 03e above): #747 CHECK rc=0 AT 48 GB; STAGE2 BUILDS rc=0; stage2 EXECUTION has a diagnosed defect class

MAIN LINE: healthy, untouched (docs-only commit here). Before ANY
reseed: probe candidate as ORCHESTRATOR (#757).

#747 STATE: branch `747-flip` @ 840476d6 (3 commits this session:
5b8f086c sema reuse, c5ae2982 interner scan diet, 840476d6 CLI clone
wraps). Worktree recipe unchanged. Seed gate rc=0 after each commit.

THE MEMORY WALL IS DOWN. Two root causes, both found by profiling the
live process (WITH_PROFILE=1 phase lines + lldb bt at the allocators —
`sample`(1) cannot unwind With frames; lldb can):
1. Full `check` ran sema TWICE. run_mir_lower built a fresh
   Sema.init+check_module after the frontend already ran frontend.sema
   on the same pool (the "died INSIDE run_mir_lower" from 03c was the
   SECOND check_module, not lower_module). Fix: run_mir_lower now
   reuses zcu.last_sema via the emit_typed guard (decl_count match +
   types_frozen==0 fallback; diags continuity = takes zcu.diagnostics
   exactly like Sema.init did). MIR-phase sema profile: 55 s full
   recheck -> 3.6 s preregister-only. Seed-checker lesson: after
   `sema = move self.zcu.last_sema` you must REINITIALIZE the field
   (placeholder) before any later read; sync-inside-a-method does not
   satisfy the checker.
2. intern_str/pool_intern miss-scan cloned EVERY existing symbol text
   per miss (flip wrapper had put with_str_clone_ref INSIDE the scan
   loop; every NEW symbol is a miss; emit_drop_stmt interns a UNIQUE
   `drop#<id> ...` origin per drop stmt). O(N^2) leaked bytes in the
   seed-built stage1 = the real firehose, in frontend.resolve, sema,
   AND lower_module. Fix: compare through element views (the eq
   helpers take &str), clone only for the map insert on the at-most-one
   match — pool_lookup_symbol's scan was already this shape.
   frontend.resolve fell 72 s -> 1.6 s.

NUMBERS (cap WITH_MEMORY_LIMIT_BYTES=118111600640 unless noted):
- baseline check: rc=125 committed=118 GiB at t=146 s (peak footprint
  127.8 GB and still climbing; 03c uncapped runs OS-killed ~90 GB RSS).
- after fix 1: rc=125, death moved into real lower_module.
- after fix 1+2: `with-stage1 check src/main.w` rc=0 "ok" in 76 s,
  peak footprint 48.2 GB, mir.lower 21 s bodies=7146, all MIR/async
  validators green, ZERO diagnostics (census still 0 through the new
  code).
- STAGE2 BUILDS: `with-stage1 build src/main.w -O1` rc=0 in 137 s,
  peak 57.6 GB, 16 llvm units + link + dsymutil complete. First
  flipped stage1->stage2 binary ever: /tmp/flip-stage2-probe.

STAGE2 EXECUTION: --version ok; everything that touches strings hits a
DIAGNOSED systemic defect class: consuming-str externs that kept their
pre-flip ABI (with_str_byte_at/slice/starts_with/contains/eq per the
step-1 carve-out) MOVE their argument and reset the caller's slot, but
the flipped CHECKER NEVER DIAGNOSES these use-after-move sites —
census-zero does NOT cover consuming extern args. lldb proof:
find_source_arg passed arg to with_str_byte_at then kept using it ->
reset slot -> source="" ("check requires a source file"). Also
left-to-right arg evaluation makes with_str_slice(arg, 9,
with_str_len(arg)) read the reset slot. Fixed the CLI-critical sites
by with_str_clone_ref wraps (commit 840476d6; `run FILE` now finds and
reads the file). Remaining instances immediately behind it: parser
returns an empty module for any source ('-e' and file builds), and
stage2 `check src/main.w` panics "str to C string conversion: interior
NUL byte" at t=0.01 s. Known same-class residue: ComptimeEval string
intrinsics (recv_value.text passed consuming then reused, ~7 sites),
main.w test-harness starts_with chains (~20), misc (29 raw
byte_at/slice sites grepped total; starts_with/contains/eq not yet
counted).

NEXT (in order):
1. FIX THE CHECKER GAP: consuming extern-fn str args must produce
   use-of-moved diagnostics like any other move. Then re-census (it
   will be >0 again — that is the point), and let wrap_diag_spans
   mechanically wrap the new bucket. Do NOT whack-a-mole stage2 sites
   by hand: each iteration costs a stage1+stage2 rebuild (~6 min).
   Decision for Eric: per-site clone wraps vs flipping those extern
   decls to &str (dedup trap: codegen EMITS these symbols for method
   spellings — one symbol, two ABIs) vs teaching codegen to emit _ref
   twins. The wrap is the safe both-worlds default.
2. Then re-smoke stage2 (-e, run, check src/main.w — expect the
   drastically lower footprint claim to finally be measurable), then
   stage2->stage3 fixpoint attempt.
3. Then the 03c tail: lib/std de-Copy leftovers, corpus sweep, un-pin
   emitc cap, :move-audit/:drop-audit, battery ALONE, reseed (as
   ORCHESTRATOR per #757).

REVIEW ITEMS FOR ERIC (this session):
- run_mir_lower sema reuse (5b8f086c): architectural change, both
  worlds — check/build now run ONE sema pass. Frontend sema had
  emit_config_warnings=1 + ci_omitted_symbols set; the reused sema
  keeps them (fresh path had 0/empty). Main-line wins the same ~50 s
  and the same peak-memory halving when this lands.
- Interner scan (c5ae2982): the miss-scan itself is O(N) compares per
  NEW symbol (quadratic overall) even clone-free, and exists only as
  insurance against a symbol_map that is never actually stale
  (intern_type/intern_value trust their maps with no scan). Deleting
  the scan is a main-line candidate; not done on the flip branch.
- rt with_arg_at/with_getenv_str return make_str-wrapped FOREIGN
  pointers (OS argv/environ) typed as owned str; flipped callers drop
  them (free skipped defensively by rt_payload_start_is_owned=0, so
  no crash, but the type is a lie). Honest fix post-reseed: return
  fresh clones or &str.

TRAPS confirmed again: macOS `sample` cannot unwind With frames (flat
towers under the entry frame) — use lldb breakpoint sampling for
attribution. zsh harness (not fish). WITH_PROFILE=1 phase lines are
the cheap phase-attribution tool; the memory-limit trip line self-
reports committed bytes.

## SESSION-RESUME (2026-08-03c, SUPERSEDED by 03d above): #747 sema census 0 PROVEN (rc=0); MirLower is the wall

MAIN LINE: healthy, untouched. Before ANY reseed: probe candidate as
ORCHESTRATOR (#757).

#747 STATE: branch `747-flip` @ 7d8544fe (2 commits this session:
d4828774 accessor flips, 7d8544fe census fixes). Worktree recipe
unchanged.

HOT-ACCESSOR CONVERSIONS (all -> &str, seed gate rc=0 after each round):
- Ast.get_string, CiIR get_string (all 4 pools), InternPool
  .resolve_symbol + .resolve, Sema.pool_resolve_symbol + .pool_resolve,
  MirLower.symbol_text. Tails return pool storage directly.
- cc_intern_resolve (CCodegen) kept `-> str` + explicit clone: it takes
  InternPool BY VALUE, and the seed rejects a view returned out of a
  consumed param ("returned view may outlive its origin").
- Seed lesson: `let st = self.state` then view-from-st is rejected
  (origin = local); inline `self.state.xs.get(...)` is accepted.
- Seed's mutate-while-view rule then fired wherever an unannotated
  binding held a view into self across a `self.emit_*`/mut call: 99
  bindings (88 wave-1 + 11 wave-2) + ~14 owned-into-view-binding
  assigns, all rewritten to `let/var X: str = with_str_clone_ref(...)`
  (scratch tool clone_bindings.w, session scratchpad). These ~110
  clones sit on cold diagnostic/bounded mangling paths; #748 view
  tokens can recover them later.

CENSUS (flipped stage1, check src/main.w): 185 errors post-conversion
-> 0. 149 wrapper edits (wrap_diag_spans; kinds return/if-copy/
assignment/wrong-arg/vec-push) + hand fixes: SemaDecl primitive-type
lookup respelled `with_str_eq(clone(name),"i8")` -> `name == "i8"`
(18 sites, zero-clone), main.w test_/bench_ filters -> .starts_with,
3 mixed-arm `let name = if ...` clones (Codegen/Analysis), MirLower
generic_call_symbol_text tail, SemaCheck collect_target_type arm.

SEMA CENSUS ZERO IS PROVEN, rc=0: `with-stage1 check src/main.w
--dump-typed >/dev/null` exits 0 with ZERO diagnostics (128 s, peak
RSS 91.8 GB). emit_typed_file = compile_file (full sema pipeline that
emitted every census error 1232->0) + serialization, NO MirLower. This
is the completion proof the 03b session could not get.

FULL `check` STILL DIES — and the wall is now precisely located:
use-of-moved is a SEMA diagnostic, so every erroring census only ever
exercised compile_file; run_mir_lower has NEVER completed under the
flip. Evidence this session: 3 uncapped full checks OS-killed at
90-90.5 GB peak RSS (251-388 s wall, zero diagnostics); capped run
WITH_MEMORY_LIMIT_BYTES=96GiB exits rc=125 at committed=96 GiB at
t=123 s INSIDE run_mir_lower. Demand is >96 GiB with the sema phase
alone fitting fine (~92 GB incl. typed dump). MirLower-phase
allocation volume is the next trim target, not sema accessors.

STAGE2 PROBE (flipped stage1 build src/main.w -O1): rc=125 both
attempts, pure memory failure, no crash/codegen error.
- default cap: committed=64 GiB at 79 s.
- WITH_MEMORY_LIMIT_BYTES=96GiB: committed=96 GiB at 128 s, and the
  trip site matches the capped check EXACTLY (requested=730784, same
  committed within 65 KB) — stage2 dies at the same run_mir_lower
  allocation as check, before codegen starts. Same wall, not a new
  failure mode.

NEXT: (a) trim MirLower/prepare-hook clone volume the way sema
accessors were trimmed (find the per-body allocation hogs; note the
seed-built stage1 leaks every transient str, so volume == footprint),
(b) or run the roundtrip on a bigger box (>96 GiB committed needed;
total unknown — measure with a higher cap there), (c) or chunked
compilation. Then: lib/std de-Copy leftovers, corpus sweep, un-pin
emitc cap, :move-audit/:drop-audit, battery ALONE, reseed (as
ORCHESTRATOR per #757).

REVIEW ITEMS FOR ERIC (this session):
- Observer accessors returning &str (list above) — API-shape call
  made without a brief; conforms to D5 observers + the #748 direction.
- SemaDecl primitive-name lookup now uses str == (operator lowers to
  the same STR_EQ path; removes 18 per-lookup clones).
- ~110 annotated `: str = with_str_clone_ref(...)` bindings restore
  one clone each at diagnostic/mangling sites; flagged for #748.

TRAPS confirmed again: `with` one-liners with cwd inside the worktree
emit garbage (bit once more via a `with -p` respell attempt — output
went to scratchpad, source untouched; redo from /Users/eric/with was
correct). The harness shell here is zsh, not fish — `set x (cmd)`
fails; use POSIX syntax. RSS sampling under memory pressure is
misleading (compressor): use /usr/bin/time -l peak + the allocator's
own committed= trip line for verdicts.

## SESSION-RESUME (2026-08-03b, SUPERSEDED by 03c above): #747 census 571 -> 0* (zero UNPROVEN — see caveat)

MAIN LINE: healthy. Seed + installed = v0.15.1-g0f663361e. Before ANY
future reseed: probe candidate as ORCHESTRATOR (#757).

#747 STATE: branch `747-flip` @ 76c5bde0 (8 commits this session).
Census 571 -> 66 verified by COMPLETED check runs with full
diagnostics at every step. The final batch (66 -> 0) has a caveat:
after it, every `with-stage1 check src/main.w` attempt (4 tries)
emitted ZERO diagnostics through a full-length pass (~150 s user)
but was SIGKILLED by the OS under memory pressure before the `ok`
exit — the check's footprint (RSS ~90 GB, VSZ 600+ GB reserved,
swap 60+ GB) now exceeds what this 128 GB box tolerates. So census
ZERO is PROBABLE (zero diagnostics ever emitted, and the wrapper
plans no edits) but no run has produced rc=0 + `ok`. FIRST TASK NEXT
SESSION: verify on a quiet box, or trim check-path clone volume
first (see below), or bisect which final-batch edit inflated the
check footprint. census8 (66 errors) at c57eca73 was the last
provably-completing check. moveprobe still shows exactly the
intentional move error (rc=1, no crash); HashMap/concat/observer
probes all compile AND RUN correctly under the flipped stage1.
Worktree recipe unchanged (git worktree add /tmp/wt-flip 747-flip +
.deps symlink; rebuild stage1 via `src/main build :stage1`, ~3 min).

Census trajectory: 571 -> 351 (wrapper round 3: `return <expr>` +
complex single-line return spans) -> 331 (round 4: borrowed else-arms)
-> 294 (COMPILER FIX: D22 observer keys) -> 271 (wrapper kind 7:
&str args at consuming str params) -> 119 (hand-fix ~45 use-of-moved
MOVERS + concat codegen fix) -> 66 (wrapper kinds 8/9: if-copy arms,
D22 assignment/typed-binding) -> 0 (struct-literal heads + Lsp
doc_text snapshots + residue).

TWO REAL COMPILER BUGS found by probing (both fixed on the branch):
- 24f38e97: HashMap.get/contains + Vec.contains keys — checker
  demanded owned K (masked pre-flip by Copy materialization) AND
  MirLower lowered the key as a consuming move: under the flip the
  first m.get(k) BLANKED k (second lookup missed, k.len()==0).
  Now: checker expects &K (owned args auto-ref), MirLower
  lower_observer_probe_arg emits a non-consuming OK_COPY share
  (deref for &K args; rvalues become registered statement temps —
  --debug-alloc leak count=0). remove keeps owned K (D22 transfer).
- 1f679268: `s ++ "!"` with s: &str concatenated the POINTER bytes
  as a str header (garbage). Both concat paths (RK_BIN_OP dispatch,
  STR_CONCAT_N chain emitter) now run operands through
  mir_coerce_compare_operand — the #293 "&str reads its pointee"
  coercion comparisons already used.

STAGE2 PROBE (flipped stage1 building the compiler): BLOCKED by the
seed-built-stage1 memory wall, NOT debugged further (per plan).
- default cap: `memory limit exceeded` at 64 GiB, ~84 s, rc=125.
- WITH_MEMORY_LIMIT_BYTES=0 on the 128 GB box: OS-killed after
  ~15 min wall (VSZ 600+ GB committed, swap ~66 GB, ~98% CPU but
  mostly paging), no compiler output, no artifact.
This is the EXPECTED #744 class: stage1 is SEED-BUILT, so its own
transient strings never free (pre-flip semantics are baked into the
binary), and the campaign's clone insertions amplify the volume.
Heals only at reseed, when a flipped compiler (whose clones DO free)
builds itself. Chicken-and-egg: the reseed candidate must first be
BUILT by the leaky stage1. Options for next session: (a) reduce
clone volume in the hottest paths before the stage2 attempt —
convert Ast.get_string / InternPool.resolve_symbol / CiIR.get_string
to &str returns and fix their consuming callers (bounded set, worth
it), (b) per-module/chunked compilation to bound peak, (c) a bigger
box. Option (a) is the most with-y and also the #748 direction.

NEXT (Phase C tail per plan): lib/std de-Copy leftovers (build.w
Package/ProjectInfo/Diagnostics/Workspace; JsonView = design question
for Eric), corpus sweep, un-pin emitc_migrate cap, then the
stage1->stage2 attempt AFTER a strategy for the seed-built-stage1
memory wall (options: run cap-off on a big box / chunked build /
accept and reseed via the direct compile+link path like the g43df7f0d8
recovery), :move-audit/:drop-audit, battery ALONE, reseed. After
reseed: respell rt str_ref_view/clone_ref honestly, re-audit
consuming-str extern calls, revisit hot-accessor clones (#748):
Ast.get_string, InternPool.resolve_symbol, CiIR.get_string,
Lexer/Parser/Source full-text clones, intern_symbol map-key clone.

REVIEW ITEMS FOR ERIC (semantic calls made this session):
- D22 observer-key compiler fix (above) — semantics change landed
  without a brief; conforms to the ruling's get/contains-&K text.
- std API flips: sha256_hash_str, sha256_hash_str_pair -> &str
  (lib/std/crypto/sha256.w), str_copy_bytes -> &str
  (lib/std/internal/str_abi.w). Pure observers per D5.
- print/eprint(s: str) in std.builtins stay CONSUMING; two compiler
  call sites clone at the arg. Flip-to-&str is a lib/std de-Copy-tail
  design question.
- CImport.w:10671 global save/restore snapshot now CLONES (a move
  left the global moved for every reader on the success path).
- Lsp handlers take an owned snapshot of doc text per request.

TRAPS (new this session, on top of the standing list):
- NEVER run `with` one-liners (-e/-n/-p) with cwd INSIDE the
  worktree: the one-liner binary links the worktree's flipped rt and
  reads/writes garbage (an 18k-line `with -p` pass emitted all-blank
  lines; same command from outside is correct). This is the known
  seed-vs-worktree linking trap in a new spelling. `with run tool.w`
  with absolute paths from OUTSIDE the worktree is safe.
- fish pipe-status: `cmd | head` reports head's rc — never pipe a
  verdict-bearing check (bit again this session).
- The census check's footprint grew with each clone batch: at
  c57eca73 it completed in ~165 s CPU; at 76c5bde0 it emits all
  diagnostics but gets OS-killed near the end on this box. Budget
  memory/time accordingly (or trim clones first).

TOOLS: tools/wrap_diag_spans.w now handles kinds: Vec.push, D22
call-arg/struct-field, struct-literal mismatch, assignment, return
(incl. `return <expr>` statements + complex single-line spans),
wrong-arg (&str at consuming str, label-gated), if-copy arms, D22
assignment/typed-let-binding, typed-binding RHS. Build it OUTSIDE the
worktree; run with cwd inside. It planned zero edits against the last
diagnostics that exist (census8).

<!-- SESSION-RESUME-747-FLIP-HAND-FIX inserted below; older resume follows (superseded) -->

## SESSION-RESUME (2026-08-03): everything an agent needs (SUPERSEDED by 2026-08-03b above)

MAIN LINE: healthy. Seed + installed = v0.15.1-g0f663361e (battery 11
green, orchestration-probed). Before ANY future reseed: probe candidate
as ORCHESTRATOR (rm out/lib/rt_core.o; candidate build :rt-core-object)
— #757.

#747 STATE: branch `747-flip` (in the main repo's git; commits safe).
The WORKTREE DIRECTORY lives in a session scratchpad under /private/tmp
and may be GARBAGE-COLLECTED — if missing, recreate:
  git worktree add /tmp/wt-flip 747-flip && ln -s /Users/eric/with/.deps /tmp/wt-flip/.deps
Rebuild flipped stage1 (also the unflipped-world gate, must exit 0):
  cd <wt> && /Users/eric/with/src/main build :stage1   (~3 min)
Census: out/bootstrap/bin/with-stage1 check src/main.w  → currently
571 errors. Probe flip-active: a trivial `let b = a; print(a)` str
program must give exactly one use-of-moved error, rc=1, NO crash.

NEXT WORK (hand-fix, in order): (1) 234 return-type tails — mostly
`xs.get(i)` view tails and multiline if/match tails, CImport-heavy
(61); wrap tail in with_str_clone_ref or return &str where the fn is
an observer; (2) 47 HashMap get/contains/insert sites; (3) 149
use-of-moved (read-before-move reorder or clone at move site); (4) 50
struct-literal multiline heads; then lib/std de-Copy tail (build.w
Package/ProjectInfo/Diagnostics/Workspace; JsonView = design question
for Eric), corpus sweep, un-pin emitc_migrate cap, flipped
stage1→stage2, :move-audit/:drop-audit, battery ALONE, reseed,
roundtrip (#5 emit-C roundtrip task resumes then).

TOOLS ON THE BRANCH: tools/wrap_diag_spans.w (diag-span clone wrapper,
dry), tools/migrate_param_borrows.w + drive_param_borrow_fixpoint.w
(param migration, fixpointed), denylist keyed fn\tparam.

TRAPS (learned hard, do not relearn): every edit must be BOTH-worlds
valid (seed compiles it AND flipped stage1 accepts); extern decl
flips are global-per-symbol (one stale decl = phantom error); tool
binaries with flipped decls must be built OUTSIDE the worktree (seed's
embedded rt wins linking inside); frozen seed miscompiles
`(s:&str) as *const str` (#758 — heals at post-flip reseed; rt
clone_ref/slice_ref carry BOOTSTRAP INTERIM spelling `**(&s as *const
*const *const u8)` — respell honestly after reseed); if-expression
temporaries cannot auto-borrow at &str args (hoist to a binding);
fish unquoted $files passes ONE arg (quote or use listfiles).

OPEN ISSUES FILED THIS SESSION: #755 element-view marshalling
miscompile (land before/with flip), #756 cross-module method adoption,
#757 reseed orchestration gate, #758 seed &str cast miscompile.
#743 (failed-action teardown corrupt-vec) got two more data points —
still open, failure-path only.
