# Config resolution. Each entry maps the file name a consumer repo would use
# to the copy full-lint bundles; a gate asks `cfg <name>` for the path to pass
# its tool. A consumer file of that name wins over the bundled copy (the repo
# owner's call, not full-lint's), and every such override is reported so it
# never passes silently.
# shellcheck shell=bash

config_names=()
config_bundled=()

config_add() {
	config_names+=("$1")
	config_bundled+=("$FULL_LINT_ROOT/$2")
}

config_add .markdownlint-cli2.jsonc shared/.markdownlint-cli2.jsonc
config_add .gitleaks.toml .gitleaks.toml
config_add .jscpd.json .jscpd.json
config_add .yamllint.yaml .yamllint.yaml
config_add lychee.toml lychee.toml

cfg() {
	local i
	for i in "${!config_names[@]}"; do
		[[ "${config_names[$i]}" == "$1" ]] || continue
		if [[ -f "$1" ]]; then
			printf '%s\n' "$PWD/$1"
		else
			printf '%s\n' "${config_bundled[$i]}"
		fi
		return 0
	done
	echo "full-lint: no bundled config named $1" >&2
	return 1
}

report_overrides() {
	local file
	for file in "${config_names[@]}"; do
		[[ -f "$file" ]] || continue
		echo "override: $file (bundled copy not used)"
		if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
			echo "::warning file=$file::override: $file (bundled copy not used)"
		fi
	done
}
