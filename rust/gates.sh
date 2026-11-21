# The Rust gate set: the commands the old rust/ci.yml ran, registered once
# for ./gates, the reusable GitHub workflow and the GitLab entry point.
# shellcheck shell=bash

# CI parity: warnings fail every Rust gate locally too, not only on CI.
export RUSTFLAGS="-D warnings"

# clippy reads clippy.toml from CLIPPY_CONF_DIR; pointing it at the bundled
# copy only when the repo has none keeps a local clippy.toml in charge.
if [[ ! -f clippy.toml && ! -f .clippy.toml ]]; then
	export CLIPPY_CONF_DIR="$FULL_LINT_ROOT/rust"
fi

config_add .typos.toml rust/.typos.toml
config_add deny.toml rust/deny.toml
config_add clippy.toml rust/clippy.toml
config_add .clippy.toml rust/clippy.toml

managed block Cargo.toml rust/Cargo.toml.example
managed file rust-toolchain.toml rust/rust-toolchain.toml

# shellcheck disable=SC2034 # read by bin/full-lint's `tools` command
code_tools=(cargo-llvm-cov arborist)
# shellcheck disable=SC2034
hygiene_tools+=(cargo-deny cargo-shear)
# shellcheck disable=SC2034
mutation_tools=(cargo-mutants)

# Single quotes are deliberate: each command is evaluated when its gate runs.
# shellcheck disable=SC2016
{
	gate code format 'cargo fmt --all -- --check'
	gate code lint 'cargo clippy --workspace --all-targets -- -D warnings'
	# The doc-quality lints are rustdoc's and fire under no other gate.
	gate code doc 'RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps'
	gate code tests 'cargo test --workspace'
	# Gate and report in one pass: llvm-cov writes the report before it
	# evaluates the fail-under switches, so CI can upload a failing run's
	# report. It lands in target/ so no hygiene gate running beside it scans
	# it.
	gate code coverage 'cargo llvm-cov --workspace --fail-under-lines 95 --fail-under-regions 95 --fail-under-functions 95 --lcov --output-path target/lcov.info'
	# Threshold 15 is Sonar's S3776 default, the parity anchor every
	# language here gates at; arborist has no config file, so it lives here.
	# Measured divergences from the spec are in rust/README.md.
	gate code cognitive 'arborist --threshold 15 --exceeds-only --gitignore --languages rust .'
	gate code file-length '"$FULL_LINT_ROOT/rust/effective-lines-gate.sh"'

	register_hygiene

	gate hygiene deny-advisories 'cargo deny --config "$(cfg deny.toml)" check advisories'
	gate hygiene deny-licenses 'cargo deny --config "$(cfg deny.toml)" check licenses'
	gate hygiene deny-bans 'cargo deny --config "$(cfg deny.toml)" check bans'
	gate hygiene unused-deps 'cargo shear --deny-warnings'
	gate hygiene todo-policy 'rc=0; git grep --untracked --no-recurse-submodules -nE "TODO|FIXME" -- "*.rs" || rc=$?; test "$rc" -eq 1'
	gate hygiene sync-check drift_check
}

# Cargo.lock packages with no `source` line are built from this repo's tree.
lang_own_packages() {
	[[ -f Cargo.lock ]] || return 0
	awk '/^\[\[package\]\]/ { emit(); name = ""; src = 0 }
		/^name = / { name = $3; gsub(/"/, "", name) }
		/^source = / { src = 1 }
		function emit() { if (name != "" && !src) print "crates.io " name }
		END { emit() }' Cargo.lock
}

lang_fix() {
	cargo fmt --all
	shell_files | xargs -r -d '\n' shfmt -w
}

# The run's own zero-missed mode exits 2 on any surviving mutant, and
# equivalent mutants (a clamp's boundary comparisons return the same bound
# either way) survive every test, so the floor below is the gate. Any other
# non-zero exit is an internal error and stays red: outcomes.json is written
# incrementally, and a crashed run's partial data must not read as green.
# Floor 85: reason in rust/README.md's mutation-testing section. The results
# land in target/ so no hygiene gate scans the mutated source copies.
lang_mutation() {
	local code=0
	cargo mutants --output target || code=$?
	if [[ "$code" -ne 0 && "$code" -ne 2 ]]; then
		echo "cargo mutants failed with exit $code"
		return "$code"
	fi
	python3 -c "import json, sys; s = json.load(open('target/mutants.out/outcomes.json')); score = 100 * s['caught'] // s['total_mutants']; print('mutation score %d%% (caught %d/%d, floor 85)' % (score, s['caught'], s['total_mutants'])); sys.exit(0 if score >= 85 else 1)"
}
