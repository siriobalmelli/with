{
  fetchurl,
  gcc,
  lib,
  lld,
  ninja,
  stdenv,
}:

let
  linuxCxxRuntimeFlags = lib.optionalString stdenv.hostPlatform.isLinux " -static-libstdc++ -static-libgcc";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "withlang-cmake";
  version = "4.2.3";

  src = fetchurl {
    url = "https://github.com/Kitware/CMake/releases/download/v${finalAttrs.version}/cmake-${finalAttrs.version}.tar.gz";
    hash = "sha256-fvrM3oxaayloutbOD+YOGbbhBwGhL86UjCv3m6yKEek=";
  };

  nativeBuildInputs = [
    lld
    ninja
  ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    gcc.cc.lib
  ];

  configurePhase = ''
    runHook preConfigure
    CC="${stdenv.cc}/bin/clang" \
      CXX="${stdenv.cc}/bin/clang++" \
      LD="${lld}/bin/ld.lld" \
      LDFLAGS="''${NIX_LDFLAGS:-} -fuse-ld=lld${linuxCxxRuntimeFlags}" \
      ./bootstrap \
      --prefix="$out" \
      --parallel="$NIX_BUILD_CORES" \
      --generator=Ninja \
      --no-system-libs \
      -- \
      -DBUILD_TESTING=OFF \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_MAKE_PROGRAM=${ninja}/bin/ninja \
      -DCMAKE_USE_OPENSSL=OFF
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    ${ninja}/bin/ninja -j "$NIX_BUILD_CORES"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    ${ninja}/bin/ninja install
    runHook postInstall
  '';

  doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
  installCheckPhase = ''
    runHook preInstallCheck
    case "$("$out/bin/cmake" --version)" in
      "cmake version ${finalAttrs.version}"*) ;;
      *) exit 1 ;;
    esac
    runHook postInstallCheck
  '';

  meta = {
    description = "Cross-platform build system";
    homepage = "https://cmake.org";
    license = lib.licenses.bsd3;
    mainProgram = "cmake";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
})
