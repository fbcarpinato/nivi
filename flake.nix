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
            tree-sitter
            tree-sitter-grammars.tree-sitter-zig
          ];

          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"
            export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local"
            export TREE_SITTER_ZIG_PARSER="${pkgs.tree-sitter-grammars.tree-sitter-zig}/parser"
            export TREE_SITTER_ZIG_HIGHLIGHTS="${pkgs.tree-sitter-grammars.tree-sitter-zig}/queries/highlights.scm"
            echo "nivi dev shell: zig $(zig version)"
          '';
        };
      });
    };
}
