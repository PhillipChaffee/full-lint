#!/usr/bin/env bash
# Self-test for lib/drift.sh through the real entry point
# (bin/full-lint rust sync [--check]) on fixture repos in a temp dir.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
sha=1111111111111111111111111111111111111111

fail() {
	echo "FAIL  $1"
	failures=$((failures + 1))
}

# check <name> <expected exit> <pattern the output must match, or EMPTY>
# <args>: runs `full-lint rust <args>` in the fixture repo.
check() {
	local name=$1 want=$2 pattern=$3 out rc
	shift 3
	out="$(cd "$work/repo" && FULL_LINT_SHA="${pin_sha:-$sha}" "$root/bin/full-lint" rust "$@" 2>&1)"
	rc=$?
	if [[ "$rc" -ne "$want" ]]; then
		fail "$name: exit $rc, want $want"
		printf '%s\n' "$out" | sed 's/^/      /'
	elif [[ "$pattern" == "EMPTY" ]]; then
		if [[ -n "$out" ]]; then
			fail "$name: expected no output"
			printf '%s\n' "$out" | sed 's/^/      /'
		else
			echo "PASS  $name"
		fi
	elif ! grep -qE -- "$pattern" <<<"$out"; then
		fail "$name: output lacks /$pattern/"
		printf '%s\n' "$out" | sed 's/^/      /'
	else
		echo "PASS  $name"
	fi
}

fresh_repo() {
	rm -rf "$work/repo"
	mkdir -p "$work/repo/.github/workflows"
	git -C "$work/repo" init -q
	printf '[package]\nname = "demo"\nversion = "0.1.0"\nedition = "2024"\n\n[dependencies]\n' >"$work/repo/Cargo.toml"
	printf 'jobs:\n  gates:\n    uses: PhillipChaffee/full-lint/.github/workflows/rust.yml@%s  # v0.1.0\n' "$sha" >"$work/repo/.github/workflows/ci.yml"
	cp "$root/consumer/gates" "$work/repo/gates"
}

# edit <sed expression> <file>: one in-place edit of a fixture file.
edit() {
	sed -i -e "$1" "$work/repo/$2"
}

fresh_repo
check "fresh manifest has no managed block" 1 'no full-lint managed block' sync --check
check "fresh manifest misses the lints opt-in" 1 'does not inherit the workspace lints' sync --check
check "fresh repo misses rust-toolchain.toml" 1 'rust-toolchain.toml: error: missing' sync --check
check "sync writes the managed files" 0 'wrote Cargo.toml' sync
check "synced repo passes" 0 'match full-lint' sync --check
cp "$work/repo/Cargo.toml" "$work/synced.toml"
cp "$work/repo/rust-toolchain.toml" "$work/synced-toolchain.toml"
check "second sync writes nothing" 0 EMPTY sync
cmp -s "$work/repo/Cargo.toml" "$work/synced.toml" || fail "second sync changed Cargo.toml"
grep -qx 'workspace = true' "$work/repo/Cargo.toml" || fail "sync did not add [lints] workspace = true"

edit '/^todo = "warn"$/a large_futures = "warn"' Cargo.toml
check "unmarked addition fails" 1 'Cargo.toml:[0-9]+: error: unmarked: \[workspace.lints.clippy\] large_futures' sync --check

edit 's/^large_futures = "warn"$/large_futures = "warn"  # exception: futures cross an await-heavy API/' Cargo.toml
check "marked addition passes" 0 'match full-lint' sync --check
check "marked addition warns" 0 'warning: Cargo.toml:[0-9]+: exception: \[workspace.lints.clippy\] large_futures = "warn" \(futures cross an await-heavy API\)' sync --check
check "a passing sync-check gate still prints the warning" 0 '^warning: Cargo.toml:[0-9]+: exception' sync-check
out="$(cd "$work/repo" && GITHUB_ACTIONS=true FULL_LINT_SHA=$sha "$root/bin/full-lint" rust sync --check 2>&1)"
if grep -qE '^::warning file=Cargo.toml,line=[0-9]+::exception' <<<"$out"; then
	echo "PASS  marked addition annotates on GitHub"
else
	fail "no ::warning annotation under GITHUB_ACTIONS=true"
fi

edit 's/# exception: futures cross an await-heavy API/# exception:/' Cargo.toml
check "marker without a reason fails" 1 'needs a reason' sync --check
edit 's/# exception:$/# exception: futures cross an await-heavy API/' Cargo.toml

edit 's/^unwrap_used = "warn"$/unwrap_used = "allow"  # exception: prototypes panic freely/' Cargo.toml
check "changed canonical value fails even with a marker" 1 'changed: \[workspace.lints.clippy\] unwrap_used = "allow" \(canonical: "warn"' sync --check

edit '/^missing_docs = "deny"$/d' Cargo.toml
check "removed canonical key fails" 1 'missing: \[workspace.lints.rust\] missing_docs = "deny"' sync --check

edit '/^\[workspace.lints.rust\]$/a unknown_lints = "deny"' Cargo.toml
check "sync reports the dropped unmarked key" 0 'dropped \[workspace.lints.rust\] unknown_lints \(no exception marker\)' sync
check "sync restores the canonical floor" 0 'match full-lint' sync --check
grep -q '^large_futures = "warn"  # exception: futures cross an await-heavy API$' "$work/repo/Cargo.toml" || fail "sync lost the exception line"
grep -q '^unwrap_used = "warn"$' "$work/repo/Cargo.toml" || fail "sync did not reset unwrap_used"
cp "$work/repo/Cargo.toml" "$work/with-exception.toml"
check "sync with an exception is idempotent" 0 EMPTY sync
cmp -s "$work/repo/Cargo.toml" "$work/with-exception.toml" || fail "second sync with an exception changed Cargo.toml"

edit 's/^unsafe_code = "forbid"$/unsafe_code = "forbid"  # exception: duplicate/' Cargo.toml
check "sync drops a marker on a key that is canonical now" 0 'dropped the exception marker on \[workspace.lints.rust\] unsafe_code' sync
check "and the result passes" 0 'match full-lint' sync --check

# shellcheck disable=SC2016 # sed's $ is the last line, not a variable
edit '/^\[lints\]$/,$d' Cargo.toml
check "manifest without [lints] fails" 1 'does not inherit the workspace lints' sync --check
check "sync appends [lints]" 0 'wrote Cargo.toml' sync
check "and the result passes" 0 'match full-lint' sync --check

edit '/^components = /a targets = ["wasm32-unknown-unknown"]  # exception: the crate ships a wasm build' rust-toolchain.toml
check "toolchain exception passes with a warning" 0 'warning: rust-toolchain.toml:[0-9]+: exception: \[toolchain\] targets' sync --check
edit 's/^channel = .*/channel = "1.90.0"/' rust-toolchain.toml
check "changed toolchain channel fails" 1 'rust-toolchain.toml:[0-9]+: error: changed: \[toolchain\] channel' sync --check
check "toolchain sync keeps the exception" 0 'wrote rust-toolchain.toml' sync
grep -q '^targets = \["wasm32-unknown-unknown"\]  # exception: the crate ships a wasm build$' "$work/repo/rust-toolchain.toml" || fail "toolchain sync lost the exception"
grep -q '^channel = "1.98.0"$' "$work/repo/rust-toolchain.toml" || fail "toolchain sync did not reset the channel"

printf 'jobs:\n  mutation:\n    uses: PhillipChaffee/full-lint/.github/workflows/rust-mutation.yml@%s\n' 2222222222222222222222222222222222222222 >"$work/repo/.github/workflows/mutation.yml"
check "disagreeing pins fail" 1 'pin different full-lint commits' sync --check
rm "$work/repo/.github/workflows/mutation.yml"
pin_sha=3333333333333333333333333333333333333333 check "a pin other than the running commit fails" 1 'pin 1111111111111111111111111111111111111111 but this run uses 3333333333333333333333333333333333333333' sync --check
pin_sha=local check "a local checkout skips the commit comparison" 0 'match full-lint' sync --check

echo '# edited' >>"$work/repo/gates"
check "an edited gates stub fails" 1 'gates: error: differs' sync --check
check "sync restores the stub" 0 'wrote gates' sync
cmp -s "$work/repo/gates" "$root/consumer/gates" || fail "sync did not restore gates"

if [[ "$failures" -gt 0 ]]; then
	echo "$failures drift test(s) failed"
	exit 1
fi
echo "all drift tests pass"
