---
name: init-rust-repo
description: >-
  Initializes a new Rust repository that adopts full-lint's strict Rust stack by
  reference to one pinned full-lint commit, not by copying configs: a committed
  ./gates stub, caller workflows for full-lint's reusable GitHub workflows (and a
  GitLab include when the repo lives on GitLab), and the managed Cargo.toml lint
  block and rust-toolchain.toml. The gates are clippy pedantic/nursery/cargo plus
  restriction picks, the rustdoc stable group and missing_docs denied, arborist
  cognitive complexity at 15, a 1000 effective-line file cap, cargo llvm-cov at
  >=95% on lines, regions and functions, cargo-deny, cargo-shear, and the shared
  hygiene gates, run the same way locally, on GitHub and on GitLab. Use when the
  user asks to initialize, bootstrap, or set up a new Rust project or repository
  with strict linting, documentation enforcement, and a code-coverage gate.
---

# Initialize a strict Rust repository

Sets up a brand-new Rust repository so that `./gates` runs full-lint's Rust
gates at one pinned full-lint commit: `cargo check` fails on any
undocumented public item, `cargo doc` fails on any broken doc link, clippy's
strict groups run as errors, any function above cognitive complexity 15 or
file above 1000 effective lines fails, and coverage below 95% fails the
build. The repo copies none of full-lint's configs; they arrive with the
pin. Read full-lint's `rust/README.md` for the reasoning behind every
piece; the steps below assume that reasoning and only record the work.

# Preconditions

- Linux x86_64 for `./gates tools` (the pinned binaries are Linux x86_64
  assets; the install script refuses elsewhere).
- `git`, `curl`, `rustup` (it honors `rust-toolchain.toml`), Node.js with
  npm, and Python 3 with `venv` (markdownlint-cli2, jscpd and yamllint
  install through them).
- You know the target directory, the package name, and whether the repo is
  on GitHub, GitLab, or both.

# Steps

1. Create the repository: `cargo init --lib <name>` (or `cargo init <name>`
   for a binary). Fill the `[package]` metadata clippy's `cargo` group
   checks: `description`, `license`, `repository`, `readme`, `keywords`,
   `categories`.
2. Pick the full-lint commit: the commit of the latest `v*` tag, or main's
   HEAD until the first tag exists. Use the peeled commit for an annotated
   tag:

   ```bash
   git ls-remote --tags https://github.com/PhillipChaffee/full-lint 'v*'
   git ls-remote https://github.com/PhillipChaffee/full-lint refs/heads/main
   ```

   Write the full 40-hex SHA everywhere below, with the tag (or `main`) as
   a trailing comment. Never pin a branch or a tag name: the SHA is what
   makes a pin immutable.
3. On GitHub, write `.github/workflows/ci.yml`:

   ```yaml
   permissions:
     contents: read  # least privilege: no job writes to the repo
   name: CI

   on:
     push:
       branches: [main]
     pull_request:

   # The called workflow sets no concurrency of its own (its
   # github.workflow would be this file's name), so the caller owns it.
   concurrency:
     group: ${{ github.workflow }}-${{ github.ref }}
     cancel-in-progress: true

   jobs:
     full-lint:
       uses: PhillipChaffee/full-lint/.github/workflows/rust.yml@<sha>  # <tag>
   ```

   A crate whose build links system libraries passes them to the code job
   (`with: apt-packages: "<packages>"`); rust/README.md lists the other
   inputs. Then `.github/workflows/mutation.yml`:

   ```yaml
   permissions:
     contents: read  # least privilege: no job writes to the repo
   name: mutation

   on:
     schedule:
       - cron: "23 4 * * *"  # nightly, off the hour so it does not race the shared-runner rush
     workflow_dispatch:  # manual trigger to verify the gate without waiting for the schedule

   jobs:
     full-lint:
       uses: PhillipChaffee/full-lint/.github/workflows/rust-mutation.yml@<sha>  # <tag>
   ```

4. Copy full-lint's `consumer/gates` at that commit to `./gates`, byte for
   byte, and `chmod +x gates`.
5. On GitLab, write `.gitlab-ci.yml` with the include, run `./gates version`
   (it reads the pin you just wrote), and add the `integrity` line it
   prints:

   ```yaml
   include:
     - remote: https://raw.githubusercontent.com/PhillipChaffee/full-lint/<sha>/gitlab/rust.yml
       integrity: sha256-<from ./gates version>
   ```

   A repo on both forges keeps both files on the same SHA; `./gates`
   refuses to run when they disagree.
6. `./gates sync`: writes the managed `[workspace.lints]` block into
   Cargo.toml, adds `[lints] workspace = true`, and writes
   `rust-toolchain.toml`. Edit neither by hand except to add a line with a
   trailing `# exception: <reason>`; a changed or removed canonical line
   fails `sync-check`.
7. `./gates tools`, then `./gates`. Make every gate pass or fail for a
   known, acceptable reason. `missing_docs = "deny"` means an undocumented
   pub item FAILS the build: write the doc or scope a
   `#[expect(missing_docs, reason = "...")]`, never weaken the lint. An
   over-threshold function or over-cap file FAILS: split it, never raise a
   threshold. A config the repo must differ on (say, a crate name for
   `.typos.toml`) goes in a repo file of that name; `./gates` then reports
   `override: <file> (bundled copy not used)` on every run.
8. Prove the coverage gate: comment out one test, run
   `./gates coverage`, and see it fail below 95%; restore the test and see
   it pass.
9. Merge the comment rules from full-lint's `rust/AGENTS.md.example` into
   the new repo's `AGENTS.md` as its "Comment and doc-comment rules"
   section (adapt the last rule's domain mention to the project's).
10. Wire the free coverage badge: the reusable workflow uploads
    `target/lcov.info` to Coveralls on the built-in GITHUB_TOKEN (free for
    a public repo). Add to the README, after the first push:
    `![coverage](https://coveralls.io/github/OWNER/REPO/badge.svg?branch=main)`
    with OWNER/REPO replaced by the GitHub slug.
11. Commit everything in one bootstrap commit: `gates`, the CI files,
    Cargo.toml, Cargo.lock, rust-toolchain.toml, the sources, AGENTS.md.

# Gates

- After step 7, `./gates` prints `all gates pass` (or a documented,
  pre-existing decision explains any red).
- Step 8 saw the coverage gate fail, then pass.
- If `./gates tools` or the coverage gate cannot run (no llvm-tools, a
  crate that cannot be instrumented, a non-Linux machine), STOP and report
  the tooling failure; do not proceed with a gate quietly missing.

# Upgrading later

Move the SHA (and the tag comment) in every CI file, update the GitLab
`integrity` from `./gates version`, then run `./gates sync` and `./gates`.
`sync` also refreshes `./gates` itself when full-lint's stub changed.
