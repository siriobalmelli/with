{
  fetchurl,
  gcc,
  lib,
  lld,
  python3,
  stdenv,
}:

let
  linuxCxxRuntimeFlags = lib.optionalString stdenv.hostPlatform.isLinux " -static-libstdc++ -static-libgcc";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "withlang-ninja";
  version = "1.13.1";

  src = fetchurl {
    url = "https://github.com/ninja-build/ninja/archive/refs/tags/v${finalAttrs.version}.tar.gz";
    hash = "sha256-8AVa0Dab8uNylVulUSjQAM/MIXdwV4BgFbReSsy+vyM=";
  };

  nativeBuildInputs = [
    lld
    python3
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
      python configure.py --bootstrap
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ninja "$out/bin/ninja"
    runHook postInstall
  '';

  doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
  installCheckPhase = ''
    runHook preInstallCheck
    test "$("$out/bin/ninja" --version)" = "${finalAttrs.version}"
    runHook postInstallCheck
  '';

  meta = {
    description = "Small build system with a focus on speed";
    homepage = "https://ninja-build.org";
    license = lib.licenses.asl20;
    mainProgram = "ninja";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
})
