{
  lib,
  buildNpmPackage,
  nodejs_24,
  makeWrapper,
  github-cli,
  util-linux,
}:
buildNpmPackage {
  pname = "caz-website-updater";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: type: lib.cleanSourceFilter path type && baseNameOf path != "node_modules";
  };
  nodejs = nodejs_24;
  npmDepsHash = "sha256-FEaxYvedlF4pLPjY6VvAEyCc1NA4Y0fZZZv++7DREnY=";
  nativeBuildInputs = [ makeWrapper ];
  dontNpmBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm run check
    npm test
    runHook postCheck
  '';
  # Node refuses type stripping below a node_modules directory. Install our
  # TypeScript as application code, with dependencies alongside it.
  installPhase = ''
    runHook preInstall
    npm prune --omit=dev --ignore-scripts
    mkdir -p "$out/lib/caz-website-updater" "$out/bin"
    cp -r src node_modules package.json "$out/lib/caz-website-updater/"
    makeWrapper ${nodejs_24}/bin/node "$out/bin/caz-website-updater" \
      --add-flags "$out/lib/caz-website-updater/src/cli.ts" \
      --prefix PATH : ${
        lib.makeBinPath [
          github-cli
          util-linux
        ]
      }
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    cat > config.json <<EOF
    {"mode":"preview","stateDirectory":"$TMPDIR/installed-website-state","healthUrl":"http://127.0.0.1:8088/","retain":3,"minimumAgeDays":30}
    EOF
    "$out/bin/caz-website-updater" --config config.json status
    runHook postInstallCheck
  '';
  meta = {
    description = "Verified static website deployment with atomic activation and rollback";
    mainProgram = "caz-website-updater";
    platforms = lib.platforms.linux;
  };
}
