{
  cmake,
  fetchurl,
  gcc,
  lib,
  lld,
  ninja,
  python3,
  stdenv,
  llvmPackages,
}:
let
  cmakeModuleVersion = lib.versions.majorMinor cmake.version;
  linuxCxxRuntimeFlags = lib.optionalString stdenv.hostPlatform.isLinux " -static-libstdc++ -static-libgcc";
in
stdenv.mkDerivation (
  finalAttrs: with finalAttrs; {
    pname = "withlang-llvm";
    version = "22.1.6";

    src = fetchurl {
      url = "${passthru.urlBase}/llvmorg-${version}/llvm-project-${version}.src.tar.xz";
      sha256 = "6e0b376a1f6d9873e7dfb09ae6e04b9c7024400f01733fa4c29be69d5c138bc2";
    };
    sourceRoot = "llvm-project-${version}.src/llvm";

    nativeBuildInputs = [
      cmake
      lld
      ninja
      python3
    ];

    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      gcc.cc.lib
    ];

    cmakeFlags = [
      "-DCMAKE_C_COMPILER=${stdenv.cc}/bin/clang"
      "-DCMAKE_CXX_COMPILER=${stdenv.cc}/bin/clang++"
      "-DCMAKE_LINKER=${lld}/bin/ld.lld"
      "-DCMAKE_EXE_LINKER_FLAGS_INIT=-fuse-ld=lld${linuxCxxRuntimeFlags}"
      "-DCMAKE_MODULE_LINKER_FLAGS_INIT=-fuse-ld=lld${linuxCxxRuntimeFlags}"
      "-DCMAKE_SHARED_LINKER_FLAGS_INIT=-fuse-ld=lld${linuxCxxRuntimeFlags}"
      "-DCMAKE_MAKE_PROGRAM=${ninja}/bin/ninja"
      "-DLLVM_ENABLE_PROJECTS=clang;lld"
      "-DLLVM_TARGETS_TO_BUILD=${passthru.llvmTargetsToBuild}"
      "-DLIBCLANG_BUILD_STATIC=ON"
      "-DLLVM_ENABLE_PIC=ON"
      "-DBUILD_SHARED_LIBS=OFF"
      "-DLLVM_BUILD_LLVM_DYLIB=OFF"
      "-DLLVM_LINK_LLVM_DYLIB=OFF"
      "-DCLANG_LINK_CLANG_DYLIB=OFF"
      "-DLLVM_INCLUDE_TESTS=OFF"
      "-DLLVM_INCLUDE_BENCHMARKS=OFF"
      "-DLLVM_INCLUDE_EXAMPLES=OFF"
      "-DCLANG_INCLUDE_TESTS=OFF"
      "-DCLANG_BUILD_EXAMPLES=OFF"
      "-DLLVM_ENABLE_ZLIB=OFF"
      "-DLLVM_ENABLE_ZSTD=OFF"
      "-DLLVM_ENABLE_LIBXML2=OFF"
      "-DLLVM_ENABLE_TERMINFO=OFF"
      "-DLLVM_ENABLE_LIBEDIT=OFF"
    ];

    dontUseCmakeConfigure = true;

    configurePhase = ''
      runHook preConfigure
      ${cmake}/bin/cmake -G Ninja -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$out" \
        ${lib.escapeShellArgs cmakeFlags}
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      ${cmake}/bin/cmake --build build --parallel "$NIX_BUILD_CORES"
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      ${cmake}/bin/cmake --build build --target install --parallel "$NIX_BUILD_CORES"
      install -Dm755 ${cmake}/bin/cmake "$out/bin/cmake"
      install -Dm755 ${cmake}/bin/ctest "$out/bin/ctest"
      install -Dm755 ${cmake}/bin/cpack "$out/bin/cpack"
      install -Dm755 ${ninja}/bin/ninja "$out/bin/ninja"
      mkdir -p "$out/share"
      cp -a ${cmake}/share/. "$out/share/"
      runHook postInstall
    '';

    postInstall = ''
      mkdir -p "$out/nix-support"
      cp build/CMakeCache.txt "$out/nix-support/CMakeCache.txt"
    '';

    doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;

    installCheckPhase = ''
      runHook preInstallCheck
      require_executable() {
        if ! test -x "$1"; then
          printf 'missing executable: %s\n' "$1" >&2
          exit 1
        fi
      }
      require_file() {
        if ! test -f "$1"; then
          printf 'missing file: %s\n' "$1" >&2
          exit 1
        fi
      }
      require_directory() {
        if ! test -d "$1"; then
          printf 'missing directory: %s\n' "$1" >&2
          exit 1
        fi
      }
      require_executable "$out/bin/clang"
      require_executable "$out/bin/clang++"
      require_executable "$out/bin/cmake"
      require_executable "$out/bin/ctest"
      require_executable "$out/bin/cpack"
      require_executable "$out/bin/ninja"
      require_executable "$out/bin/lld"
      require_executable "$out/bin/llvm-nm"
      require_executable "$out/bin/llvm-readobj"
      require_executable "$out/bin/llvm-strip"
      require_executable "$out/bin/ld.lld"
      require_executable "$out/bin/ld64.lld"
      require_executable "$out/bin/lld-link"
      require_executable "$out/bin/wasm-ld"
      require_file "$out/include/clang-c/Index.h"
      require_file "$out/lib/libclang.a"
      require_directory "$out/lib/clang"
      require_file "$out"/lib/clang/*/include/stddef.h
      mkdir cmake-smoke
      printf '%s\n' \
        'cmake_minimum_required(VERSION 3.25)' \
        'project(with_sdk_cmake_smoke NONE)' \
        'include(CMakeParseArguments)' \
        > cmake-smoke/CMakeLists.txt
      PATH="$out/bin:$PATH" \
        CC="$out/bin/clang" \
        CXX="$out/bin/clang++" \
        "$out/bin/cmake" -S cmake-smoke -B cmake-smoke/build
      printf '%s\n' 'checking SDK Clang frontend'
      printf '%s\n' '#include <stddef.h>' 'size_t with_sdk_clang_smoke;' > clang-smoke.c
      PATH="$out/bin:$PATH" "$out/bin/clang" -c clang-smoke.c -o clang-smoke.o
      printf '%s\n' 'checking SDK CMAKE_ROOT'
      printf '%s\n' 'file(WRITE "cmake-root.txt" "''${CMAKE_ROOT}\n")' > cmake-smoke/cmake-root.cmake
      "$out/bin/cmake" -P cmake-smoke/cmake-root.cmake
      require_file cmake-root.txt
      IFS= read -r cmake_root < cmake-root.txt
      if ! test "$cmake_root" = "$out/share/cmake-${cmakeModuleVersion}"; then
        printf 'unexpected CMAKE_ROOT: %s\n' "$cmake_root" >&2
        exit 1
      fi
      printf '%s\n' 'checking copied tool versions'
      "$out/bin/ctest" --version
      "$out/bin/cpack" --version
      test "$("$out/bin/ninja" --version)" = "${ninja.version}"
      printf '%s\n' 'checking concrete lld drivers'
      "$out/bin/ld.lld" --version
      "$out/bin/ld64.lld" --version
      "$out/bin/lld-link" --version
      "$out/bin/wasm-ld" --version
      runHook postInstallCheck
    '';

    passthru = {
      llvmTargetsToBuild = "AArch64;X86"; # both expected by rt/llvm_bridge.w
      bootstrapCompiler = llvmPackages.clang-unwrapped;
      urlBase = "https://github.com/llvm/llvm-project/releases/download";
    };

    meta = {
      description = "With-owned static LLVM, Clang, and lld SDK";
      homepage = "https://github.com/withlang-dev/with";
      license = lib.licenses.asl20;
      platforms = lib.platforms.darwin ++ lib.platforms.linux;
    };
  }
)
