let
  # These single-FROM Dockerfiles are image manifests consumed directly by Nix.
  # Dependabot updates the same tag/digest used by oci-containers; no image build.
  readImage =
    path:
    let
      match = builtins.match "FROM ([^[:space:]@]+:[^[:space:]@:/]+@sha256:[0-9a-f]{64})[[:space:]]*" (
        builtins.readFile path
      );
    in
    if match == null then
      throw "Expected a single digest-pinned FROM instruction in ${toString path}"
    else
      builtins.head match;
in
{
  home-assistant = readImage ./home-assistant/Dockerfile;
  minecraft = readImage ./minecraft/Dockerfile;
}
