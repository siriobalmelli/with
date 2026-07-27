{
  fetchurl,
  lib,
  stdenv,
}:

let
  source = {
    src = fetchurl {
      url = "https://github.com/withlang-dev/with/releases/download/v0.15.1/with-darwin-aarch64";
      hash = "sha256-3oT5wNwDpO1cz4O3XasMXw8bfKC7i6Tl/hZBWlCNa7I=";
    };
    versionOutput = "with v0.15.1-gf58b95617";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "withlang-bin";
  version = "0.15.1";

  src = source.src;

  doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;

  dontBuild = true;
  dontStrip = true;
  dontUnpack = true;

  installCheckPhase = ''
    runHook preInstallCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    test "$($out/bin/with version)" = "${source.versionOutput}"
    test "$($out/bin/with -e 'print("hello, with")')" = "hello, with"
    runHook postInstallCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    install -m0755 "$src" "$out/bin/with"
    runHook postInstall
  '';

  meta = {
    description = "Prebuilt With programming language compiler";
    homepage = "https://github.com/withlang-dev/with";
    license = lib.licenses.mit;
    mainProgram = "with";
    maintainers = with lib.maintainers; [ siriobalmelli ];
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
