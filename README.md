<div align="center">

# modules

**Opaque cross-repo dependencies for a public repo.**

Manage repo-level dependencies with an encrypted manifest and a gitignored clone directory.
A public observer sees only 'this repo uses modules' — no names, no pinned commits, no count.

![lang: bash](https://img.shields.io/badge/lang-bash-4EAA25?style=flat&logo=gnubash&logoColor=white)
[![tests: 123 passing](https://img.shields.io/badge/tests-123%20passing-brightgreen?style=flat)](test/)
![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=flat)

</div>

<br />

## Why

Git submodules require `.gitmodules`, a plaintext file that exposes dependency URLs and paths. Git-crypt can't encrypt it (git needs to parse it as INI config).

Naive `git clone` inside a parent repo does better — it creates a mode 160000 gitlink, no `.gitmodules` needed — but still leaks information: the directory name and the pinned commit SHA are both visible in the git tree, and the SHA is globally searchable on GitHub (it resolves back to the upstream repo).

**modules** goes all the way: git tracks nothing under the clone directory. All submodule state — names, URLs, pinned commits — lives in an encrypted manifest at `.modules/manifest`. Clones land in a gitignored `modules/` directory (path configurable). Public observers learn _that_ the feature is in use; nothing else.

## Quick start

`modules setup` initializes git-crypt via rudi when needed, assigns the manifest for encryption, and installs hooks/merge driver. Pass `--gpg-key` when setting up a repo meant to be cloned elsewhere; without a collaborator key, the encrypted manifest is local-only until you add and commit a rudi user.

```bash
# Install
shiv install modules

# Initialize in your repo (defaults to modules/ as the clone root)
modules setup --gpg-key <your-fingerprint>
git commit -m "init modules"

# Or pick a different clone root
modules setup --path deps --gpg-key <your-fingerprint>

# Add a dependency
modules add https://github.com/org/repo.git --name my-dep
git commit -m "add my-dep"

# Add a dependency that should refresh from main during init
modules add https://github.com/org/shared-notes.git --name shared-notes --track main
git commit -m "add tracked shared-notes module"

# See what you have
modules list
modules status

# On a fresh clone: unlock, then populate from the manifest
modules unlock && modules init

# Or initialize only the modules this environment is expected to clone
modules init my-dep shared-notes
```

## How it works

Locally, after `modules unlock && modules init`:

```
  your-repo/
  ├── .modules/
  │   ├── manifest       ← encrypted TSV (name\turl\tpin[\ttrack])
  │   └── config         ← plaintext JSON ({"path": "modules"})
  ├── modules/          ← gitignored; real git clones live here
  │   ├── fold/
  │   └── den/
  ├── .gitignore        ← contains 'modules/'
  └── .gitattributes    ← .modules/manifest filter=git-crypt merge=modules-manifest
```

What a public observer sees on GitHub (locked):

```
  your-repo/
  ├── .git-crypt/
  ├── .modules/
  │   ├── manifest       (ciphertext, opaque)
  │   └── config         ({"path": "modules"})
  ├── .gitignore
  └── .gitattributes
```

- **No gitlinks** — nothing under the clone directory is tracked by git. No pinned commit SHAs leak.
- **Encrypted manifest** — `.modules/manifest` holds all submodule state (name, URL, pin, and optional tracking branch). `modules setup` initializes [rudi](https://github.com/KnickKnackLabs/rudi) when needed and assigns the manifest to git-crypt.
- **Readable names on disk** — no hashing. `cd modules/fold` just works.
- **Optional branch tracking** — modules added with `--track main` refresh their local clone during `modules init` without updating the recorded pin. Use `modules update` when you want to advance and stage the durable pin.
- **Selected initialization** — `modules init fold den` initializes only the named modules. With no names, `modules init` initializes every manifest entry. Failure is still fatal for every selected module.
- **Custom clone root** — `modules setup --path deps` picks a different location (e.g., `deps/`, `third-party/vendored/`). Stored in `.modules/config`.
- **Merge-safe manifest** — a git-crypt-aware merge driver handles concurrent pin bumps without corrupting the manifest. Installed by default.

<br />

## Commands

| Command                                                              | Description                                                               |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `modules add <url> [--name <name>] [--ref <ref>] [--track <branch>]` | Add a submodule                                                           |
| `modules init [names]...`                                            | Clone modules and refresh tracked clones from their branch                |
| `modules install-hooks`                                              | Install git merge driver for the modules manifest                         |
| `modules list [--json]`                                              | List modules                                                              |
| `modules lock`                                                       | Lock encrypted manifest (re-encrypt on disk)                              |
| `modules ls [--json]`                                                | Alias for list                                                            |
| `modules merge-driver <ancestor> <current> <other>`                  | Custom git merge driver for .modules/manifest (invoked by git, not users) |
| `modules remove <name>`                                              | Remove a module                                                           |
| `modules setup [--path <path>] [--gpg-key <fingerprint>]`            | Initialize modules in the current repo                                    |
| `modules status`                                                     | Show status of all modules                                                |
| `modules unlock`                                                     | Unlock encrypted manifest using your GPG key                              |
| `modules update [name] [--commit]`                                   | Pull latest, update module pin(s), and optionally commit                  |

<br />

## Testing

```bash
git clone https://github.com/KnickKnackLabs/modules.git
cd modules && mise trust && mise install
mise run test
```

**123 tests** across 13 suites, using [BATS](https://github.com/bats-core/bats-core). All tests use local git repos in temp directories — no network, no external dependencies.

The `git-mechanics` suite verifies git's behavior around gitignored nested repos. The `merge-driver` suite simulates concurrent pin bumps to validate the manifest merge logic. The `roundtrip` suite drives the full setup → add → lock → fresh-clone → unlock → init path end-to-end with git-crypt.

## Architecture

```
modules/
├── .mise/tasks/
│   ├── setup           # Initialize manifest, config, gitignore, hooks, merge driver
│   ├── add             # Clone into modules/<name>, record in manifest
│   ├── init            # Populate modules; refresh tracked clones from their branch
│   ├── list            # Show modules (table or --json)
│   ├── status          # Show at-pin / changed / missing
│   ├── update          # Pull latest, update pinned SHA, optionally commit
│   ├── remove          # Clean removal of clone + manifest entry
│   ├── lock / unlock   # Wrappers around rudi lock / unlock
│   ├── install-hooks   # Register the merge driver (called by setup)
│   └── test            # Run BATS test suite
├── lib/
│   ├── common.sh                  # Shared helpers, manifest ops
│   ├── hooks.sh                   # Merge-driver installer
│   └── manifest-merge-driver.sh   # git-crypt-aware 3-way merge
├── hooks/
│   ├── dispatcher
│   ├── gitmodules-guard           # Pre-commit: reject .gitmodules
│   └── manifest-encryption        # Pre-commit: block plaintext manifest
├── test/
│   ├── test_helper.bash
│   ├── common.bats
│   ├── setup.bats
│   ├── add.bats
│   ├── list.bats
│   ├── init.bats
│   ├── update.bats
│   ├── status.bats
│   ├── remove.bats
│   ├── hooks.bats
│   ├── git-mechanics.bats         # Behavior around gitignored nested repos
│   ├── merge-driver.bats          # Concurrent-edit regression tests
│   └── roundtrip.bats             # Full setup → lock → clone → unlock → init
└── mise.toml
```

## Migration from pre-v0.9.0

v0.9.0 is a breaking change: old-layout repos (hashed paths under `submodules/`, JSON manifest, gitlinks) need a one-shot migration to the new opacity layout. See the migration script and instructions at [modules#16](https://github.com/KnickKnackLabs/modules/issues/16).

**Breaking changes:**

- Clone-root is `modules/` (was `submodules/` with hashed paths). Configurable via `modules setup --path <dir>`.
- Manifest is tab-separated (was JSON). No user-facing format; matters only for anyone scripting against `.modules/manifest` directly.
- `modules list --json` schema: each module is now `{url, pin}`. The pre-v0.9.0 schema included `path`; module paths are now derived from `.modules/config`'s `path` field, not stored per-module.
- `.modules/config` carries a `version` field. Mismatched clients refuse to operate rather than silently misbehaving.

<br />

<div align="center">

---

<sub>
Your dependencies, visible only to those who should see them.<br />
<br />
This README was generated from <a href="https://github.com/KnickKnackLabs/readme">README.tsx</a>.
</sub></div>
