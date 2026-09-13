{
  description = "alauncher: a lean macOS launcher and dictation app";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # No C compiler wrapper: Swift, the macOS SDK and codesign must come
          # from the installed Xcode, which Nix can't provide.
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              just
              jq
              shellcheck
            ];
            shellHook = ''
              for var in SDKROOT DEVELOPER_DIR; do
                if [[ "''${!var:-}" == /nix/store/* ]]; then
                  unset "$var"
                fi
              done
              if /usr/bin/xcode-select -p >/dev/null 2>&1; then
                echo "alauncher: $(/usr/bin/xcrun swift --version 2>/dev/null | head -n 1)"
              else
                echo "alauncher: Xcode not found; install it and run xcode-select -s" >&2
              fi
            '';
          };
        }
      );
    };
}
