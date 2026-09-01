# nivi

Nivi is an experimental Vim-style terminal editor written in Zig.

## Usage

### Nix setup

The included development shell provides Zig, ZLS, Tree-sitter, and the Zig
Tree-sitter grammar. With [Nix](https://nixos.org/) installed and flakes enabled:

```sh
nix develop
zig build -Doptimize=ReleaseSafe
./zig-out/bin/nivi path/to/file
```

If you use [direnv](https://direnv.net/), run `direnv allow` once instead of
entering `nix develop` manually.

### Manual setup

Install:

- Zig 0.16.0 or newer
- The Tree-sitter C library and headers, available to the system linker

Then build and run Nivi:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/nivi path/to/file
```

Zig syntax highlighting and syntax-aware indentation additionally require a
Tree-sitter Zig parser and query files:

```sh
export TREE_SITTER_ZIG_PARSER=/path/to/libtree-sitter-zig.so
export TREE_SITTER_ZIG_HIGHLIGHTS=/path/to/tree-sitter-zig/queries/highlights.scm
export TREE_SITTER_ZIG_INDENTS="$PWD/queries/zig/indents.scm"
```

Nivi still runs without these variables, but Zig syntax features are disabled.

### Running

Build and run directly through Zig:

```sh
zig build run -- path/to/file
```

If the path does not exist, Nivi starts with an empty buffer and creates the
file when it is saved.

The editor supports Vim-style motions, operators, counts, insert mode, and
visual mode. Common controls include:

| Keys | Action |
|---|---|
| `h`, `j`, `k`, `l` or arrow keys | Move the cursor |
| `i`, `a`, `o`, `O` | Enter insert mode |
| `Esc` | Return to normal mode |
| `u`, `Ctrl-r` | Undo and redo |
| `.` | Repeat the last change |
| `/`, `?` | Search forward or backward incrementally |
| `n`, `N` | Repeat the search in the same or opposite direction |
| `:w` | Save |
| `:q`, `:q!` | Quit, or quit without saving |
| `:wq`, `:x` | Save and quit |
| `,ut` | Toggle the undo-tree panel |
| `Ctrl-h/j/k/l` | Move focus between components |

For a non-fullscreen, scriptable interface, use line mode:

```sh
zig build run -- --line path/to/file
```

Enter `h` in line mode to list its commands.

## Development

Enter the reproducible development environment with `nix develop` or
`direnv allow`. For a manual environment, install the dependencies listed
above and set the Tree-sitter variables when syntax tests are needed.

Format and test the project:

```sh
zig fmt --check build.zig src
zig build test
```

Run benchmarks with release optimizations:

```sh
zig build bench -Doptimize=ReleaseFast
zig build bench-undo -Doptimize=ReleaseFast
zig build bench-render -Doptimize=ReleaseFast
zig build bench-vim -Doptimize=ReleaseFast
zig build bench-syntax -Doptimize=ReleaseFast
```

## License

Nivi is licensed under the [MIT License](LICENSE).
