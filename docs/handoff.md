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

## SESSION-RESUME (2026-08-03c): #747 sema census 0 PROVEN (rc=0); MirLower is the wall

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
