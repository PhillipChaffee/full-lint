#!/usr/bin/env bash
# Installs full-lint's pinned tools into <dest>/bin. CI and `./gates tools`
# both call this script, so a pin lives in exactly one place for every
# consumer; scripts/verify-sync.sh fails when hygiene.yml's own install block
# disagrees with a pin here.
#
# Every download's sha256 digest is embedded below (computed from the exact
# release asset at pin time, checked on download): a re-uploaded or
# retargeted upstream asset fails the install instead of executing. Registry
# installs (npm, pip, cargo) are version-pinned, npm runs with
# --ignore-scripts and cargo with --locked; their transitive trees resolve
# from the registry, the same recorded residual as hygiene.yml. yamllint is
# the one license exception: GPL-3.0-or-later, installed by exact pin.
#
# Idempotent: a tool whose pinned version is already installed is skipped
# (a stamp file is written only after the tool is in place, so an
# interrupted install retries on the next run).
#
# Usage: tools/install.sh <dest> <tool>...
set -euo pipefail

TYPOS_VERSION=1.50.1
LYCHEE_VERSION=0.24.2
GITLEAKS_VERSION=8.30.1
SHELLCHECK_VERSION=0.11.0
SHFMT_VERSION=3.14.0
ACTIONLINT_VERSION=1.7.12
OSV_VERSION=2.5.1
DENY_VERSION=0.20.2
SHEAR_VERSION=1.13.4
MUTANTS_VERSION=27.1.0
# cargo-llvm-cov 0.9.0 (released 2026-08-16): the version rust/README.md's
# three-axis coverage measurements were taken with, and older than the
# two-week minimum age, so a bad release has had time to be yanked.
LLVM_COV_VERSION=0.9.0
ARBORIST_VERSION=0.2.1
MARKDOWNLINT_VERSION=0.23.2
JSCPD_VERSION=5.2.0
YAMLLINT_VERSION=1.38.0

if [[ $# -lt 2 ]]; then
	echo "usage: tools/install.sh <dest> <tool>..." >&2
	exit 2
fi

# Every binary below is the Linux x86_64 asset; installing it anywhere else
# would fail later with a confusing exec error, so refuse up front.
platform="$(uname -s) $(uname -m)"
if [[ "$platform" != "Linux x86_64" ]]; then
	echo "tools/install.sh: only Linux x86_64 is supported (this machine is $platform); install the pinned versions listed in this script by hand" >&2
	exit 2
fi

mkdir -p "$1/bin" "$1/stamps"
dest="$(cd "$1" && pwd -P)"
shift
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

gh="https://github.com"

fetch() {
	local url=$1 sum=$2 out=$3
	curl --connect-timeout 10 --max-time 300 -sSfL "$url" -o "$out"
	if ! echo "$sum  $out" | sha256sum --check --status; then
		echo "tools/install.sh: sha256 mismatch for $url" >&2
		return 1
	fi
}

# from_archive <tool> <url> <sha256> <binary path inside the archive>
from_archive() {
	fetch "$2" "$3" "$tmp/$1.archive"
	mkdir "$tmp/$1"
	tar xf "$tmp/$1.archive" -C "$tmp/$1"
	install -m 0755 "$tmp/$1/$4" "$dest/bin/"
}

# from_binary <tool> <url> <sha256>: the release asset is the bare binary.
from_binary() {
	fetch "$2" "$3" "$tmp/$1"
	install -m 0755 "$tmp/$1" "$dest/bin/$1"
}

from_npm() {
	npm install --silent --no-audit --no-fund --ignore-scripts --prefix "$dest/npm" "$1@$2"
	ln -sf "../npm/node_modules/.bin/$1" "$dest/bin/$1"
}

version_of() {
	case "$1" in
	typos) echo "$TYPOS_VERSION" ;;
	lychee) echo "$LYCHEE_VERSION" ;;
	gitleaks) echo "$GITLEAKS_VERSION" ;;
	shellcheck) echo "$SHELLCHECK_VERSION" ;;
	shfmt) echo "$SHFMT_VERSION" ;;
	actionlint) echo "$ACTIONLINT_VERSION" ;;
	osv-scanner) echo "$OSV_VERSION" ;;
	cargo-deny) echo "$DENY_VERSION" ;;
	cargo-shear) echo "$SHEAR_VERSION" ;;
	cargo-mutants) echo "$MUTANTS_VERSION" ;;
	cargo-llvm-cov) echo "$LLVM_COV_VERSION" ;;
	arborist) echo "$ARBORIST_VERSION" ;;
	markdownlint-cli2) echo "$MARKDOWNLINT_VERSION" ;;
	jscpd) echo "$JSCPD_VERSION" ;;
	yamllint) echo "$YAMLLINT_VERSION" ;;
	*)
		echo "tools/install.sh: unknown tool '$1'" >&2
		return 2
		;;
	esac
}

install_tool() {
	case "$1" in
	typos)
		from_archive typos "$gh/crate-ci/typos/releases/download/v${TYPOS_VERSION}/typos-v${TYPOS_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
			edf0545109aee6a22751d04ddecb97c45be47d3aa0409564fb895eeeace91b1e typos
		;;
	lychee)
		from_archive lychee "$gh/lycheeverse/lychee/releases/download/lychee-v${LYCHEE_VERSION}/lychee-x86_64-unknown-linux-gnu.tar.gz" \
			1f4e0ef7f6554a6ed33dd7ac144fb2e1bbed98598e7af973042fc5cd43951c9a lychee-x86_64-unknown-linux-gnu/lychee
		;;
	gitleaks)
		from_archive gitleaks "$gh/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
			551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb gitleaks
		;;
	shellcheck)
		from_archive shellcheck "$gh/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
			8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"
		;;
	shfmt)
		from_binary shfmt "$gh/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64" \
			fe42021c7272ef2d67ea36cbc3031683c625d0badec733ef3a57b567246a0b66
		;;
	actionlint)
		from_archive actionlint "$gh/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
			8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 actionlint
		;;
	osv-scanner)
		from_binary osv-scanner "$gh/google/osv-scanner/releases/download/v${OSV_VERSION}/osv-scanner_linux_amd64" \
			f9f25499a2c8cc367b3af45df2ea7eeca7fbccceab9c35079968f4b3652194be
		;;
	cargo-deny)
		from_archive cargo-deny "$gh/EmbarkStudios/cargo-deny/releases/download/${DENY_VERSION}/cargo-deny-${DENY_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
			9f12ed4c49936e09b48bf862b595cde2fe64fcbd9d74dfacac6131ca824c8d5f "cargo-deny-${DENY_VERSION}-x86_64-unknown-linux-musl/cargo-deny"
		;;
	cargo-shear)
		from_archive cargo-shear "$gh/Boshen/cargo-shear/releases/download/v${SHEAR_VERSION}/cargo-shear-x86_64-unknown-linux-musl.tar.gz" \
			eb0efdfb7bd95433b5e8b9d0759a7463a30ada2bf9d54a386e2ba7d74b533d09 cargo-shear
		;;
	cargo-mutants)
		from_archive cargo-mutants "$gh/sourcefrog/cargo-mutants/releases/download/v${MUTANTS_VERSION}/cargo-mutants-x86_64-unknown-linux-gnu.tar.gz" \
			dfe6dc37d0342c891d2829b5a695aa57c2d0edecef7e7d0399a30cc6e206411e cargo-mutants
		;;
	cargo-llvm-cov)
		from_archive cargo-llvm-cov "$gh/taiki-e/cargo-llvm-cov/releases/download/v${LLVM_COV_VERSION}/cargo-llvm-cov-x86_64-unknown-linux-gnu.tar.gz" \
			b068f7c98841aacb9c4f382b4a0c184ae82f49b56a32d442b429b2961c73be15 cargo-llvm-cov
		;;
	arborist)
		# arborist ships no release binaries; --locked builds the published
		# lockfile, and its self-updater stays dormant on the analysis path.
		cargo install --quiet --locked --version "$ARBORIST_VERSION" --root "$dest" arborist-cli
		;;
	markdownlint-cli2) from_npm markdownlint-cli2 "$MARKDOWNLINT_VERSION" ;;
	jscpd) from_npm jscpd "$JSCPD_VERSION" ;;
	yamllint)
		python3 -m venv "$dest/venv"
		"$dest/venv/bin/pip" install --quiet --disable-pip-version-check "yamllint==${YAMLLINT_VERSION}"
		ln -sf ../venv/bin/yamllint "$dest/bin/yamllint"
		;;
	esac
}

for tool in "$@"; do
	version="$(version_of "$tool")"
	stamp="$dest/stamps/$tool@$version"
	if [[ -f "$stamp" ]]; then
		echo "skip     $tool $version (installed)"
		continue
	fi
	install_tool "$tool"
	touch "$stamp"
	echo "install  $tool $version"
done
