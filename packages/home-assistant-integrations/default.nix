{ inputs, runCommand }:
let
  component =
    domain: src:
    let
      manifest = builtins.fromJSON (builtins.readFile "${src}/custom_components/${domain}/manifest.json");
      inherit (manifest) version;
    in
    assert manifest.domain == domain;
    runCommand "home-assistant-${domain}-${version}" { } ''
      mkdir -p "$out"
      cp -R ${src}/custom_components/${domain}/. "$out/"
      if [ '${domain}' = scene_presets ]; then
        mkdir -p "$out/userdata"
      fi
    '';
in
{
  ha_lightfx = component "ha_lightfx" inputs.ha-lightfx-src;
  scene_presets = component "scene_presets" inputs.scene-presets-src;
}
