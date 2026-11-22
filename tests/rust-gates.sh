#!/usr/bin/env bash
# Self-test for the tree scope of rust/gates.sh through the real entry point
# (bin/full-lint rust <gate>): the source and dependency gates skip vendor/
# at any depth and still read everything else. arborist and osv-scanner are
# stand-ins that print the arguments they were handed, so the test needs no
# tool installed and no network.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
	echo "FAIL  $1"
	failures=$((failures + 1))
}

# check <name> <expected exit> <pattern> <absent pattern or ""> <gate>: runs
# one gate serially in the fixture repo with the stand-in tools first on PATH.
check() {
	local name=$1 want=$2 pattern=$3 absent=$4 out rc
	shift 4
	out="$(cd "$work/repo" && PATH="$work/fakes:$PATH" XDG_CACHE_HOME="$work/cache" "$root/bin/full-lint" rust "$@" --serial 2>&1)"
	rc=$?
	if [[ "$rc" -ne "$want" ]]; then
		fail "$name: exit $rc, want $want"
		printf '%s\n' "$out" | sed 's/^/      /'
	elif ! grep -qE -- "$pattern" <<<"$out"; then
		fail "$name: output lacks /$pattern/"
		printf '%s\n' "$out" | sed 's/^/      /'
	elif [[ -n "$absent" ]] && grep -qE -- "$absent" <<<"$out"; then
		fail "$name: output has /$absent/"
		printf '%s\n' "$out" | sed 's/^/      /'
	else
		echo "PASS  $name"
	fi
}

mkdir -p "$work/fakes"
for tool in arborist osv-scanner; do
	printf '#!/usr/bin/env bash\necho "%s args: $*"\n' "$tool" >"$work/fakes/$tool"
	chmod +x "$work/fakes/$tool"
done

rm -rf "$work/repo"
mkdir -p "$work/repo/src" "$work/repo/vendor/fork/src" "$work/repo/crates/inner/vendor/dep"
git -C "$work/repo" init -q
echo 'fn clean() {}' >"$work/repo/src/lib.rs"
echo '// TODO(upstream): theirs to resolve' >"$work/repo/vendor/fork/src/lib.rs"
echo '// FIXME(upstream): nested vendor dir' >"$work/repo/crates/inner/vendor/dep/lib.rs"
git -C "$work/repo" add -A

check "todo-policy skips vendor/ at any depth" 0 'PASS  todo-policy' '' todo-policy
check "cognitive reads src/" 0 'arborist args: .*src/lib\.rs' 'vendor/' cognitive
check "advisories skip vendor/" 0 'osv-scanner args: scan -r \. --experimental-exclude vendor$' '' advisories

echo '// TODO: ours' >>"$work/repo/src/lib.rs"
check "todo-policy still fails on the repo's own source" 1 'src/lib\.rs:2:// TODO: ours' 'vendor/' todo-policy

if [[ "$failures" -gt 0 ]]; then
	echo "$failures rust gate test(s) failed"
	exit 1
fi
echo "all rust gate tests pass"
