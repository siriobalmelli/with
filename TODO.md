# Full Source Bootstrap

This branch preserves the Nix full-source bootstrap work after the public
package was narrowed to the prebuilt compiler.

## Status

- **Darwin source build: blocked after rebase.**
  The full package passed before rebasing onto upstream `ddb05c68`.
  The `f58b95617` Darwin seed now rejects D22 ownership syntax while compiling
  stage1, including `Parser.init(..., intern, ...)` calls that require explicit
  `move` or `copy`.

- **Linux source build: blocked.**
  The published `v0.15.1` bootstrap-C bundle was emitted 595 commits before
  the Darwin seed and cannot compile the current compiler source.
  The flake does not export the known-failing Linux `withlang` package or its
  checks.

- **Source packages: not exported.**
  The branch retains the source-package implementation but does not wire it
  into the flake overlay, packages, or checks while either seed is incompatible
  with current source.

- **Linux binary package: omitted.**
  The published Linux compiler reports its version but cannot compile a
  trivial program in Nix.
  GCC rejects its lld-only flags, while lld correctly rejects the malformed
  runtime archive produced by the frozen archive writer.

- **Linux seed memory corruption: fixed locally.**
  The frozen `rt_stat` shim wrote four fields into a three-field result.
  ASan confirmed the repaired seed proceeds without that overflow.

- **Linux seed archive corruption: fixed locally.**
  The frozen writer mixed GNU indexing with incorrect eight-byte member
  alignment.
  LLVM lld accepts the repaired two-byte-aligned archives.

- **Historical bridge search: exhausted.**
  Six bounded candidates failed at different parser, build API, semantic, or
  linker compatibility boundaries.
  No merge-ready bridge chain was found.

- **Current flake evaluation: passed.**
  `nix flake check --no-build --all-systems --no-write-lock-file` succeeds.

- **Upstream bootstrap-C packaging: repaired.**
  Upstream commit `ddb05c68` repairs generated-module dependencies, duplicate
  bridges, and missing Linux shim symbols.
  A new bundle must still be generated from a compatible compiler.

## Viable Bootstrap Path

The Darwin `withlang-bin` package emitted C from the pre-rebase compiler source.
It does not compile the rebased D22 source.
The published Linux release binary also fails against current source.

Generate a new bootstrap-C bundle on Darwin, then compile and verify it on
Linux:

1. Obtain a Darwin seed or compatibility bridge that accepts current D22 source.
2. Pass Darwin build, fixpoint, test, test-green, and release verification.
3. Run `WITH_VERSION=<version> with build :package-bootstrap-c`.
4. Publish the bundle at an immutable, content-addressed location.
5. Compile the bundle on Linux with the With-owned Clang and LLVM SDK.
6. Use that compiler to run the complete Linux stage chain.
7. Pass Linux build, fixpoint, test, test-green, emit-C fixpoint, and install
   verification.
8. Update the Nix seed source and hash to the verified bundle.

## Re-enabling the Source Package

After both seeds accept current source, wire `nix/withlang` into the overlay in
two layers:

1. Build `withlang-bootstrap` with `checkPolicy = "fixpoint"`, the platform
   `withlang-seed`, and `nix/withlang/patches/seed-compat.patch` only while the
   old seed requires it.
2. Build public `withlang` with `checkPolicy = "full"`, no patches, and the
   compatibility compiler as `seedBin`.
3. Export `withlang` and its shared `passthru.tests` only after both native
   platform derivations pass every acceptance criterion below.

## Acceptance Criteria

- `packages.aarch64-darwin.withlang` builds from source and passes every gate.
- `packages.x86_64-linux.withlang` builds from source and passes every gate.
- Stage 2 and stage 3 are byte-identical on both platforms.
- Release binaries have no dynamic LLVM or Clang dependency.
- Linux release binaries depend only on the approved system runtime libraries.
- The bootstrap-C bundle has recorded source and toolchain provenance.

## Non-Goals

- Do not weaken source, fixpoint, test, or provenance checks to obtain a green
  package.
- Do not use the emitted-C bootstrap compiler as the release compiler.
- Do not use GCC, system LLVM, or mutable unpinned bootstrap inputs.
