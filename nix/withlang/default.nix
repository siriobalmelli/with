{
  bash,
  callPackage,
  coreutils,
  curl,
  fetchurl,
  gzip,
  lib,
  makeWrapper,
  checkPolicy,
  patches,
  pname,
  python3,
  role,
  seedBin,
  stdenv,
  withlang-llvm,
}:

let
  platformFiles = {
    "aarch64-darwin" = ./darwin.nix;
    "x86_64-linux" = ./linux.nix;
  };
  platformPackage = callPackage platformFiles.${stdenv.hostPlatform.system} { };

  pcre2Src = fetchurl {
    url = "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz";
    hash = "sha256-wIriOI7zM+hAPmcK1wwKEfHu0CH9iDCNfgL1lvzZ3BY=";
  };
in
platformPackage.overrideAttrs (
  finalAttrs: previousAttrs:
  let
    withlangLlvmProjectPrefix = ".deps/llvm-${withlang-llvm.version}-${previousAttrs.passthru.llvmHostName}";
    withLinkCc =
      if stdenv.hostPlatform.isLinux then "${placeholder "out"}/bin/with-cc" else "${stdenv.cc}/bin/cc";
    buildLinkCc =
      if stdenv.hostPlatform.isLinux then "${withlang-llvm}/bin/clang" else "${stdenv.cc}/bin/cc";
    wrapperArgs = [
      "--set"
      "LLVM_PREFIX"
      "${withlang-llvm}"
      "--set"
      "WITH_LIBCLANG"
      "${withlang-llvm}/lib/libclang.a"
      "--set"
      "WITH_LINK_CC"
      withLinkCc
      "--set"
      "WITH_LLVM_CC"
      "${withlang-llvm}/bin/clang"
      "--prefix"
      "PATH"
      ":"
      (lib.makeBinPath ([ withlang-llvm ] ++ lib.optional (!stdenv.hostPlatform.isLinux) stdenv.cc))
    ]
    ++ previousAttrs.passthru.wrapperArgs
    ++ [
      "--set"
      "BASH"
      "${bash}/bin/bash"
      "--set"
      "WITH_CAT"
      "${coreutils}/bin/cat"
      "--set"
      "WITH_ECHO"
      "${coreutils}/bin/echo"
      "--set"
      "WITH_ENV"
      "${coreutils}/bin/env"
      "--set"
      "WITH_FALSE"
      "${coreutils}/bin/false"
      "--set"
      "WITH_SLEEP"
      "${coreutils}/bin/sleep"
      "--set"
      "WITH_TEST"
      "${coreutils}/bin/test"
      "--set"
      "WITH_TRUE"
      "${coreutils}/bin/true"
    ];
  in
  {
    version = "0.15.1";

    src = ../../.;

    inherit patches pname;

    nativeBuildInputs = [
      bash
      coreutils
      curl
      gzip
      makeWrapper
      python3
    ]
    ++ (previousAttrs.nativeBuildInputs or [ ]);

    # Runtime objects are relocatable .o files, not executables or shared libs.
    # The package patches the compiler binary explicitly.
    dontPatchELF = true;

    postUnpack = ''
      install -m0755 ${seedBin} "$sourceRoot/src/main"
    '';

    preBuild = ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"

      export WITH="$PWD/src/main"
      with_seed_hash="$(${coreutils}/bin/sha256sum "$WITH")"
      export WITH_SEED_INPUT_SHA256="''${with_seed_hash%% *}"
      export WITH_OUT_DIR="$PWD/out"
      export LLVM_PREFIX="${withlang-llvm}"
      export WITH_LINK_CC="${buildLinkCc}"
      export WITH_LLVM_CC="${withlang-llvm}/bin/clang"
      export WITH_LIBCLANG="${withlang-llvm}/lib/libclang.a"
      export WITH_VERSION="v${finalAttrs.version}"
      export WITH_TMPDIR="$TMPDIR"

      mkdir -p .deps
      ln -sfn ${withlang-llvm} "${withlangLlvmProjectPrefix}"

      export BASH="${bash}/bin/bash"
      export WITH_CAT="${coreutils}/bin/cat"
      export WITH_ECHO="${coreutils}/bin/echo"
      export WITH_ENV="${coreutils}/bin/env"
      export WITH_FALSE="${coreutils}/bin/false"
      export WITH_SLEEP="${coreutils}/bin/sleep"
      export WITH_TEST="${coreutils}/bin/test"
      export WITH_TRUE="${coreutils}/bin/true"

      ${lib.optionalString stdenv.hostPlatform.isLinux ''
        mkdir -p "$PWD/.nix/bin"
        makeWrapper ${withlang-llvm}/bin/clang "$PWD/.nix/bin/with-cc" \
          --prefix PATH : ${withlang-llvm}/bin \
          --add-flags -fuse-ld=lld \
          ${lib.concatMapStringsSep " \\\n          " (flag: "--add-flags ${lib.escapeShellArg flag}") (
            previousAttrs.passthru.ccWrapperFlags or [ ]
          )}
        ln -s with-cc "$PWD/.nix/bin/cc"
        export WITH_LINK_CC="$PWD/.nix/bin/with-cc"
        export PATH="$PWD/.nix/bin:$PATH"
      ''}

      pcre2_dir="$PWD/out/nix-pcre2-source"
      mkdir -p "$pcre2_dir"
      tar -xzf ${pcre2Src} -C "$pcre2_dir"
      export WITH_PCRE2_SOURCE="out/nix-pcre2-source/pcre2-10.47"

    ''
    + previousAttrs.preBuild;

    buildPhase = ''
      runHook preBuild
      "$WITH" build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      PREFIX="$out" ./out/release/bin/with build :install
      runHook postInstall
    '';

    postInstall =
      (previousAttrs.postInstall or "")
      + lib.optionalString stdenv.hostPlatform.isLinux ''
        makeWrapper ${withlang-llvm}/bin/clang "$out/bin/with-cc" \
          --prefix PATH : ${withlang-llvm}/bin \
          --add-flags -fuse-ld=lld \
          ${lib.concatMapStringsSep " \\\n          " (flag: "--add-flags ${lib.escapeShellArg flag}") (
            previousAttrs.passthru.ccWrapperFlags or [ ]
          )}
      '';

    postFixup = (previousAttrs.postFixup or "") + ''
      wrapProgram "$out/bin/with" ${lib.escapeShellArgs wrapperArgs}
    '';

    doCheck = checkPolicy == "fixpoint" || checkPolicy == "full";
    checkPhase =
      if checkPolicy == "fixpoint" then
        ''
          runHook preCheck
          ./out/release/bin/with build :fixpoint
          runHook postCheck
        ''
      else if checkPolicy == "full" then
        ''
          runHook preCheck
          ./out/release/bin/with build :fixpoint
          ./out/release/bin/with build :pcre2-migrate-smoke
          test "$(./out/release/bin/with -e 'print("hello, with")')" = "hello, with"
          WITH_BUILD_JOBS=2 ./out/release/bin/with build :test
          runHook postCheck
        ''
      else
        throw "unsupported withlang check policy: ${checkPolicy}";

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      unset WITH
      unset WITH_OUT_DIR
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      test "$($out/bin/with version)" = "with v${finalAttrs.version}"
      test "$($out/bin/with -e 'print("hello, with")')" = "hello, with"
      runHook postInstallCheck
    '';

    passthru =
      previousAttrs.passthru
      // lib.optionalAttrs (checkPolicy == "full") {
        tests = (previousAttrs.passthru.tests or { }) // {
          # Keep every public source gate on the checked package derivation.
          test = finalAttrs.finalPackage;
          fixpoint = finalAttrs.finalPackage;
          pcre2-migrate-smoke = finalAttrs.finalPackage;
          smoke = finalAttrs.finalPackage;
        };
      };

    meta = {
      description = "${role} With programming language compiler";
      homepage = "https://github.com/withlang-dev/with";
      license = lib.licenses.mit;
      maintainers = with lib.maintainers; [ siriobalmelli ];
      mainProgram = "with";
      platforms = builtins.attrNames platformFiles;
    };
  }
)
