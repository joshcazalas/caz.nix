{
  inputs,
  lib,
  runCommand,
  writeText,
}:
let
  lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  homeConnectInput = lock.nodes.${lock.nodes.${lock.root}.inputs.home-connect-direct-src};
  homeConnectVersion = lib.removePrefix "v" homeConnectInput.original.ref;
  component =
    domain: src: releaseVersion:
    let
      manifest = builtins.fromJSON (builtins.readFile "${src}/custom_components/${domain}/manifest.json");
      version = if releaseVersion == null then manifest.version else releaseVersion;
    in
    assert manifest.domain == domain;
    assert releaseVersion == null || manifest.version == "0.0.0" || manifest.version == releaseVersion;
    runCommand "home-assistant-${domain}-${version}" { } ''
      mkdir -p "$out"
      cp -R ${src}/custom_components/${domain}/. "$out/"
      ${lib.optionalString (releaseVersion != null) ''
        # Match upstream's release archive: the tagged source uses a placeholder.
        rm "$out/manifest.json"
        cp ${
          writeText "${domain}-manifest.json" (builtins.toJSON (manifest // { inherit version; }))
        } "$out/manifest.json"
      ''}
      if [ '${domain}' = scene_presets ]; then
        mkdir -p "$out/userdata"
      fi
    '';
in
{
  ha_lightfx = component "ha_lightfx" inputs.ha-lightfx-src null;
  scene_presets = component "scene_presets" inputs.scene-presets-src null;
  homeconnect_ws = component "homeconnect_ws" inputs.home-connect-direct-src homeConnectVersion;
}
