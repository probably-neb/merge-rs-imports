# merge-imports

A simple tool that merges Rust `use` imports from stdin and writes the result to stdout.

## Installation

```sh
zig build --release=fast
```

The binary will be available at `zig-out/bin/merge-imports`.

## Usage

`merge-imports` reads Rust import statements from stdin, merges them, and outputs the result to stdout.
It's designed for use with the `!` filter command in Vim-compatible editors (Vim, Neovim, Zed, Helix, etc.).

It will strip `git` and `jujutsu` style merge markers.
It will not remove unused imports.
It will not format the output nicely.


### Example: Resolving a Git Merge Conflict

When you have a merge conflict in your imports:

```rust
use std::collections::{HashMap, HashSet};
<<<<<<< HEAD
use std::io::{Read, Write};
use std::sync::Arc;
=======
use std::io::{BufRead, Read};
use std::sync::{Arc, Mutex};
>>>>>>> feature-branch
```

1. Select the import block and run `:!merge-imports`

2. The imports are merged:

```rust
use std::{collections::{HashMap, HashSet, }, io::{BufRead, Read, Write, }, sync::{Arc, Mutex, }, };
```

3. Run your formatter to clean up the output
