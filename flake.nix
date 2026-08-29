{
  description = "nivi: a from-scratch Zig take on nvim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f (import nixpkgs {
            inherit system;
          }));
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "nivi-dev";

          packages = with pkgs; [
            zig
            zls
            pkg-config
          ];

          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"
            export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local"
            echo "nivi dev shell: zig $(zig version)"
          '';
        };
      });
    };
}
