#!/usr/bin/env bash
# Self-test for the reusable Rust workflow's interface: actionlint checks a
# caller's `with:` keys and value types against the called workflow's
# inputs when the call is local, so callers that use each input must lint
# clean and a caller that passes a key or type the workflow lacks must not.
# Needs actionlint on PATH (./gates tools hygiene, or hygiene.yml's install).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
	echo "FAIL  $1"
	failures=$((failures + 1))
}

# lint <name> <expected exit> <pattern or ""> <caller jobs YAML>
lint() {
	local name=$1 want=$2 pattern=$3 out rc
	printf 'permissions:\n  contents: read\nname: caller\non: pull_request\njobs:\n%s\n' "$4" >"$work/repo/.github/workflows/caller.yml"
	out="$(cd "$work/repo" && actionlint .github/workflows/caller.yml 2>&1)"
	rc=$?
	if [[ "$rc" -ne "$want" ]]; then
		fail "$name: exit $rc, want $want"
		printf '%s\n' "$out" | sed 's/^/      /'
	elif [[ -n "$pattern" ]] && ! grep -qE -- "$pattern" <<<"$out"; then
		fail "$name: output lacks /$pattern/"
		printf '%s\n' "$out" | sed 's/^/      /'
	else
		echo "PASS  $name"
	fi
}

mkdir -p "$work/repo/.github/workflows"
git -C "$work/repo" init -q
cp "$root/.github/workflows/rust.yml" "$work/repo/.github/workflows/rust.yml"

lint "a caller with no inputs" 0 '' '  gates:
    uses: ./.github/workflows/rust.yml'

# shellcheck disable=SC2016 # ${{ }} is GitHub's expression syntax, not the shell's
lint "system packages, a longer timeout, and code gates split from hygiene" 0 '' '  changes:
    runs-on: ubuntu-latest
    outputs:
      code: ${{ steps.p.outputs.code }}
    steps:
      - id: p
        run: echo code=true >>"$GITHUB_OUTPUT"
  code:
    needs: changes
    if: ${{ needs.changes.outputs.code != '"'"'false'"'"' }}
    uses: ./.github/workflows/rust.yml
    with:
      hygiene: false
      apt-packages: libgtk-3-dev xvfb
      code-timeout-minutes: 45
  hygiene:
    uses: ./.github/workflows/rust.yml
    with:
      code: false'

lint "an input the workflow lacks is refused" 1 'input "apt" is not defined' '  gates:
    uses: ./.github/workflows/rust.yml
    with:
      apt: libgtk-3-dev'

lint "a mistyped input is refused" 1 'code-timeout-minutes' '  gates:
    uses: ./.github/workflows/rust.yml
    with:
      code-timeout-minutes: forty'

if [[ "$failures" -gt 0 ]]; then
	echo "$failures workflow input test(s) failed"
	exit 1
fi
echo "all workflow input tests pass"
