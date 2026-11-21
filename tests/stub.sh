#!/usr/bin/env bash
# Self-test for consumer/gates: pin discovery, refusals, FULL_LINT_DIR, and
# the fetch-then-rename cache. The fetch runs against a local bare repo that
# git's url.<base>.insteadOf redirects the github.com URL to, so the test
# needs no network.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

fail() {
	echo "FAIL  $1"
	failures=$((failures + 1))
}

# run_stub <name> <expected exit> <pattern> [args...]: runs ./gates in the
# fixture repo with a private cache dir.
run_stub() {
	local name=$1 want=$2 pattern=$3 out rc
	shift 3
	out="$(cd "$work/repo" && XDG_CACHE_HOME="$work/cache" ./gates "$@" 2>&1)"
	rc=$?
	if [[ "$rc" -ne "$want" ]]; then
		fail "$name: exit $rc, want $want"
		printf '%s\n' "$out" | sed 's/^/      /'
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
	cp "$root/consumer/gates" "$work/repo/gates"
}

github_pin() {
	printf 'jobs:\n  gates:\n    uses: PhillipChaffee/full-lint/.github/workflows/%s.yml@%s  # v0.3.1\n' "$1" "$2" >"$work/repo/.github/workflows/$3"
}

gitlab_pin() {
	printf 'include:\n  - remote: https://raw.githubusercontent.com/PhillipChaffee/full-lint/%s/gitlab/%s.yml\n' "$2" "$1" >"$work/repo/.gitlab-ci.yml"
}

fresh_repo
run_stub "no pin refuses" 2 'need exactly one full-lint pin.*found: none' version

github_pin rust "$a" ci.yml
github_pin rust "$b" mutation.yml
run_stub "two commits refuse" 2 "found: rust $a rust $b" version

fresh_repo
github_pin rust "$a" ci.yml
github_pin go "$a" other.yml
run_stub "two languages refuse" 2 'need exactly one full-lint pin' version

fresh_repo
github_pin rust "$a" ci.yml
github_pin rust-mutation "$a" mutation.yml
gitlab_pin rust "$a"
FULL_LINT_DIR="$root" run_stub "one pin across GitHub and GitLab files runs" 0 'commit: local' version
FULL_LINT_DIR="$root" run_stub "the tag comment reaches full-lint" 0 'tag: v0.3.1' version

rm -rf "$work/repo/.github"
FULL_LINT_DIR="$root" run_stub "a GitLab-only repo runs" 0 'commit: local' version

# A bare repo holding one commit with a fake bin/full-lint stands in for
# github.com; the fake prints what it was handed.
git init -q "$work/src"
mkdir -p "$work/src/bin"
# shellcheck disable=SC2016 # the fake expands its own arguments
printf '#!/usr/bin/env bash\necho "fake full-lint lang=$1 args=${*:2} sha=$FULL_LINT_SHA tag=$FULL_LINT_TAG"\n' >"$work/src/bin/full-lint"
chmod +x "$work/src/bin/full-lint"
git -C "$work/src" add -A
git -C "$work/src" -c user.name=t -c user.email=t@example.com commit -qm fake
fake="$(git -C "$work/src" rev-parse HEAD)"
git clone -q --bare "$work/src" "$work/remote.git"
git -C "$work/remote.git" config uploadpack.allowAnySHA1InWant true
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$work/remote.git.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/PhillipChaffee/full-lint

fresh_repo
github_pin rust "$fake" ci.yml
run_stub "a pin fetches the commit and execs it" 0 "fake full-lint lang=rust args=list --serial sha=$fake tag=v0.3.1" list --serial
[[ -x "$work/cache/full-lint/$fake/bin/full-lint" ]] || fail "the fetch did not land in the cache"
rm -rf "$work/remote.git"
run_stub "a cached commit runs without fetching" 0 "fake full-lint lang=rust" list

github_pin rust "$b" ci.yml
run_stub "a failed fetch exits non-zero" 128 '' list
[[ ! -e "$work/cache/full-lint/$b" ]] || fail "a failed fetch left a cache entry"
leftovers="$(find "$work/cache/full-lint" -maxdepth 1 -name '*.fetch*')"
[[ -z "$leftovers" ]] || fail "a failed fetch left a temp dir: $leftovers"

if [[ "$failures" -gt 0 ]]; then
	echo "$failures stub test(s) failed"
	exit 1
fi
echo "all stub tests pass"
