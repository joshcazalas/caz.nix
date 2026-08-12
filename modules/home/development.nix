{
  unstablePkgs,
  ...
}:
{
  # Toolchains come from a pinned nixos-unstable revision. Projects that need
  # older versions should declare their own devShell instead of changing this
  # workstation-wide baseline.
  home.packages = with unstablePkgs; [
    cargo
    claude-code
    clippy
    codex
    docker-client
    docker-compose
    go
    nodejs
    opentofu
    rust-analyzer
    rustc
    rustfmt
    typescript
    uv
    vscode
  ];

  # Never let uv silently select a Python installation managed outside uv.
  # `uv python install` and `uv run` remain the normal workflow.
  home.sessionVariables.UV_PYTHON_PREFERENCE = "only-managed";
}
