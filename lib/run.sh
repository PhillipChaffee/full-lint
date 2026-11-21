# Gate registry and runner. A gate is a (group, name, command) row; the
# command is a bash string evaluated in the consumer repo's root, so it may
# call the functions the sourced lib/ and <lang>/gates.sh files define.
# shellcheck shell=bash

gate_groups=()
gate_names=()
gate_cmds=()

gate() {
	gate_groups+=("$1")
	gate_names+=("$2")
	gate_cmds+=("$3")
}

# select_gates <name>...: prints the registry index of every gate a group or
# gate name selects, in registry order. No names selects every gate.
select_gates() {
	local want i valid
	for want in "$@"; do
		valid=0
		for i in "${!gate_names[@]}"; do
			if [[ "$want" == "${gate_names[$i]}" || "$want" == "${gate_groups[$i]}" ]]; then
				valid=1
			fi
		done
		if [[ "$valid" -eq 0 ]]; then
			echo "full-lint: unknown gate or group '$want'; valid names: $(printf '%s\n' "${gate_groups[@]}" | awk '!seen[$0]++' | tr '\n' ' ')${gate_names[*]}" >&2
			return 2
		fi
	done
	for i in "${!gate_names[@]}"; do
		if [[ $# -eq 0 ]]; then
			echo "$i"
			continue
		fi
		for want in "$@"; do
			if [[ "$want" == "${gate_names[$i]}" || "$want" == "${gate_groups[$i]}" ]]; then
				echo "$i"
				break
			fi
		done
	done
}

list_gates() {
	local i
	for i in "${!gate_names[@]}"; do
		printf '%-9s %-20s %s\n' "${gate_groups[$i]}" "${gate_names[$i]}" "${gate_cmds[$i]}"
	done
}

# run_gates <serial 0|1> <index>...: parallel by default, every gate's output
# captured and the failing ones printed after the summary; serial streams
# each gate's output live, for reading a slow or confusing failure.
run_gates() {
	local serial=$1 i name log_dir
	shift
	log_dir="$(mktemp -d)"
	for i in "$@"; do
		name="${gate_names[$i]}"
		if [[ "$serial" -eq 1 ]]; then
			echo "=== $name"
			if (eval "${gate_cmds[$i]}") 2>&1 | tee "$log_dir/$name.log"; then
				echo "PASS  $name" | tee "$log_dir/$name.status"
			else
				echo "FAIL  $name" | tee "$log_dir/$name.status"
				echo "$name" >>"$log_dir/failed"
			fi
			continue
		fi
		(
			if (eval "${gate_cmds[$i]}") >"$log_dir/$name.log" 2>&1; then
				echo "PASS  $name" >"$log_dir/$name.status"
			else
				echo "FAIL  $name" >"$log_dir/$name.status"
				echo "$name" >>"$log_dir/failed"
			fi
		) &
	done
	wait
	if [[ "$serial" -eq 0 ]]; then
		for i in "$@"; do
			cat "$log_dir/${gate_names[$i]}.status"
		done
		# A passing gate's output stays hidden, but its warnings (a drift
		# exception, a GitHub annotation) must still reach the reader.
		for i in "$@"; do
			name="${gate_names[$i]}"
			if grep -q '^PASS' "$log_dir/$name.status"; then
				grep -hE '^(warning: |::warning )' "$log_dir/$name.log" || true
			fi
		done
	fi
	if [[ -f "$log_dir/failed" ]]; then
		if [[ "$serial" -eq 0 ]]; then
			echo "=== failing gate output ==="
			while read -r name; do
				echo "--- $name output ---"
				cat "$log_dir/$name.log"
			done <"$log_dir/failed"
		else
			echo "failed: $(tr '\n' ' ' <"$log_dir/failed")"
		fi
		rm -rf "$log_dir"
		return 1
	fi
	rm -rf "$log_dir"
	echo "all gates pass"
}
