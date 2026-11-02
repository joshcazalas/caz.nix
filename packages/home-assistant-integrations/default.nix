{ fetchFromGitHub, runCommand }:
let
  component =
    domain: version: src:
    runCommand "home-assistant-${domain}-${version}" { } ''
      mkdir -p "$out"
      cp -R ${src}/custom_components/${domain}/. "$out/"
      if [ '${domain}' = scene_presets ]; then
        mkdir -p "$out/userdata"
      fi
    '';
in
{
  ha_lightfx = component "ha_lightfx" "1.1.14" (fetchFromGitHub {
    owner = "rusty4444";
    repo = "ha-lightfx";
    rev = "3f8d9a14f8d3860d979d71e6490e8c7b9a8073e7"; # v1.1.14
    hash = "sha256-df2cwOzz6/dT1KxzNz0eBYX2tzHl/0zRT11HvWqdoxU=";
  });

  scene_presets = component "scene_presets" "2.4.0" (fetchFromGitHub {
    owner = "Hypfer";
    repo = "hass-scene_presets";
    rev = "b53280c76f6a94ea68f313c53865c3922d40b2d7"; # 2.4.0
    hash = "sha256-pHY68H0nr7eO3tGtVLtzj6cOZO3+VxC00VZmhZy+2Pk=";
  });
}
