# The shared hygiene gates every language registers, with the commands this
# repo's own hygiene.yml runs. Configs resolve through `cfg` at run time, so
# a consumer file of the same name wins and is reported.
# shellcheck shell=bash

# shellcheck disable=SC2034 # read by bin/full-lint's `tools` command
hygiene_tools=(typos markdownlint-cli2 lychee gitleaks jscpd osv-scanner shellcheck shfmt yamllint actionlint)

# Directories the dependency scans skip, by name at any depth; a language
# sets it when its ecosystem vendors sources whose lockfiles do not ship.
osv_excludes=()

osv_scan() {
	local args=() dir
	for dir in "${osv_excludes[@]}"; do
		args+=(--experimental-exclude "$dir")
	done
	osv-scanner scan -r . "${args[@]}" "$@"
}

# Tracked shell scripts, plus the committed gates stub, which has no suffix.
shell_files() {
	{
		git ls-files -- '*.sh'
		[[ -f gates ]] && echo gates
	} | sort -u
}

# A repo can be GitHub-only, GitLab-only, or both; with nothing to lint the
# gate passes and says so instead of failing on an empty glob.
workflow_yaml_lint() {
	local files=() f
	for f in .github/workflows/*.yml .gitlab-ci.yml; do
		[[ -f "$f" ]] && files+=("$f")
	done
	if [[ ${#files[@]} -eq 0 ]]; then
		echo "no .github/workflows/*.yml or .gitlab-ci.yml to lint"
		return 0
	fi
	yamllint -c "$(cfg .yamllint.yaml)" "${files[@]}"
}

workflow_lint() {
	local files=() f
	for f in .github/workflows/*.yml; do
		[[ -f "$f" ]] && files+=("$f")
	done
	if [[ ${#files[@]} -eq 0 ]]; then
		echo "no .github/workflows/*.yml to lint"
		return 0
	fi
	actionlint "${files[@]}"
}

# The licenses osv-scanner accepts across every dependency manifest; the
# same list the other language folders carry.
license_allow='MIT,Apache-2.0,ISC,BSD-3-Clause,BSD-2-Clause,MPL-2.0,PSF-2.0,Unicode-3.0,Python-2.0,Unlicense,CC0-1.0,0BSD,Apache-1.1,BSD-3-Clause-Clear,LGPL-3.0-only,BlueOak-1.0.0,CC-BY-3.0'

# The packages a repo builds itself are not its dependencies, and they have
# no registry license record (an unpublished crate reads UNKNOWN and fails
# the allow-list). The language's own license gate checks their manifests,
# so the scan ignores the packages <lang>/gates.sh lists as
# "<ecosystem> <name>" lines; a repo's own osv-scanner.toml stays in force.
license_check() {
	local config rc=0 ecosystem name
	config="$(mktemp)"
	{
		[[ -f osv-scanner.toml ]] && cat osv-scanner.toml
		lang_own_packages | while read -r ecosystem name; do
			printf '\n[[PackageOverrides]]\nname = "%s"\necosystem = "%s"\nlicense.ignore = true\nreason = "built by this repository, not a dependency"\n' "$name" "$ecosystem"
		done
	} >"$config"
	osv_scan --config "$config" --licenses="$license_allow" || rc=$?
	rm -f "$config"
	return "$rc"
}

# Called by <lang>/gates.sh after its code gates, so `list` and a full run
# keep the code group first. Single quotes are deliberate: each command is
# evaluated when its gate runs.
# shellcheck disable=SC2016
register_hygiene() {
	gate hygiene spell-check 'typos --config "$(cfg .typos.toml)"'
	gate hygiene markdown-lint 'markdownlint-cli2 --config "$(cfg .markdownlint-cli2.jsonc)" "**/*.md" "#target"'
	gate hygiene link-check 'lychee --no-progress --config "$(cfg lychee.toml)" .'
	gate hygiene secret-scan 'gitleaks detect --source . --redact --config "$(cfg .gitleaks.toml)"'
	gate hygiene duplication 'jscpd --config "$(cfg .jscpd.json)" .'
	gate hygiene advisories osv_scan
	gate hygiene license-check license_check
	gate hygiene shell-lint 'shell_files | xargs -r -d "\n" shellcheck'
	gate hygiene shell-format 'shell_files | xargs -r -d "\n" shfmt -d'
	gate hygiene workflow-yaml-lint workflow_yaml_lint
	gate hygiene workflow-lint workflow_lint
}
