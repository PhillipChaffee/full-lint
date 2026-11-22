# Managed-file drift check and sync. A managed TOML file is a list of
# entries keyed by (section, key) with a normalized value (the text after
# `=`, comment stripped, whitespace trimmed). Each consumer entry is one of:
#   match      canonical key, canonical value
#   changed    canonical key, different value        -> error
#   missing    canonical key absent                  -> error
#   exception  extra key with "# exception: <reason>" -> warning
#   unmarked   extra key without the marker          -> error
# A marker never excuses a changed or missing canonical key: the canonical
# set is the floor every consumer shares, additions are the only freedom.
# shellcheck shell=bash

DRIFT_BEGIN='# >>> full-lint managed (./gates sync rewrites this block; add a line with "# exception: <reason>" to extend it)'
DRIFT_END='# <<< full-lint managed'
DRIFT_FILE_HEADER='# full-lint managed (./gates sync rewrites this file; add a line with "# exception: <reason>" to extend it)'

# Managed-file table: (mode, consumer file, canonical path in full-lint).
# mode "block" manages the marked block inside a file the consumer owns
# (Cargo.toml), "file" manages the whole file. A block file whose canonical
# carries workspace lints must also opt every package in with
# `[lints] workspace = true`, or cargo applies none of them.
managed_modes=()
managed_files=()
managed_canon=()

managed() {
	managed_modes+=("$1")
	managed_files+=("$2")
	managed_canon+=("$FULL_LINT_ROOT/$3")
}

# Emits tab-separated records on stdout, one per finding or rendered line:
#   E <line> <message>   error         W <line> <message>  warning
#   N <message>          sync note     R <text>            rendered line
#   B <line> / Z <line>  block begin / end line in the consumer file
#   P <0|1>              1 when [package] has no [lints] table at all
#   O <line>             a managed section outside the block (sync refuses)
# The parser is line-shaped on purpose: managed entries are one
# `key = value` per line, and anything else inside managed content is an
# error rather than a guess.
read -r -d '' DRIFT_AWK <<'AWK' || true
function trim(s) {
	sub(/^[ \t]+/, "", s)
	sub(/[ \t\r]+$/, "", s)
	return s
}
# Returns the line without its comment; the comment text lands in CMT.
function strip(s,   i, c, q) {
	q = ""
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (q != "") {
			if (c == "\\" && q == "\"") { i++; continue }
			if (c == q) q = ""
			continue
		}
		if (c == "\"" || c == "\047") { q = c; continue }
		if (c == "#") { CMT = substr(s, i + 1); return substr(s, 1, i - 1) }
	}
	CMT = ""
	return s
}
# Classifies one line into KIND (blank, header, key, other) and sets SEC,
# KEY, VAL, MARKED.
function parse(line,   code, eq) {
	code = trim(strip(line))
	MARKED = (CMT ~ /^[ \t]*exception:[ \t]*[^ \t]/)
	EMPTYMARK = (!MARKED && CMT ~ /^[ \t]*exception:/)
	if (code == "") { KIND = "blank"; return }
	if (code ~ /^\[/) {
		KIND = "header"
		SEC = code
		gsub(/^\[+[ \t]*|[ \t]*\]+$/, "", SEC)
		return
	}
	eq = index(code, "=")
	if (eq > 1) {
		KIND = "key"
		KEY = trim(substr(code, 1, eq - 1))
		VAL = trim(substr(code, eq + 1))
		return
	}
	KIND = "other"
}
function addsec(s) {
	if (!(s in secseen)) { secseen[s] = 1; secorder[++nsec] = s }
}
FNR == NR {
	parse($0)
	if (KIND == "header") { csec = SEC; addsec(csec); next }
	if (KIND == "key") {
		id = csec SUBSEP KEY
		canon[id] = VAL
		ckeys[++nckey] = id
		cline[id] = KEY " = " VAL
	}
	next
}
{
	if (mode == "block") {
		if (index($0, begin) == 1) {
			nbegin++
			inblock = 1
			print "B\t" FNR
			bline = FNR
			sec = ""
			next
		}
		if (inblock && index($0, end) == 1) { inblock = 0; ended = 1; print "Z\t" FNR; next }
		if (!inblock) {
			parse($0)
			if (KIND == "header") outsec = SEC
			if (KIND == "header" && (SEC in secseen)) {
				print "E\t" FNR "\t[" SEC "] is outside the managed block; put the block markers around the existing lint tables, mark each line full-lint does not carry with \"# exception: <reason>\", then run ./gates sync"
				print "O\t" FNR
			}
			if (KIND == "header" && SEC == "package") haspkg = 1
			if (KIND == "header" && SEC == "lints") haslints = 1
			if (KIND == "key" && outsec == "lints" && KEY == "workspace" && VAL == "true") lintsws = 1
			next
		}
	}
	parse($0)
	if (KIND == "blank") next
	if (KIND == "header") { sec = SEC; next }
	if (KIND == "other") {
		print "E\t" FNR "\tunrecognized line (managed content holds one `key = value` per line): " trim($0)
		next
	}
	id = sec SUBSEP KEY
	where = "[" sec "] " KEY
	seen[id] = FNR
	if (id in canon) {
		if (VAL != canon[id]) {
			print "E\t" FNR "\tchanged: " where " = " VAL " (canonical: " canon[id] "; a canonical value cannot be overridden)"
			print "N\treset " where " to " canon[id]
		} else if (MARKED) {
			print "N\tdropped the exception marker on " where " (the key is canonical now)"
		}
		next
	}
	if (MARKED) {
		print "W\t" FNR "\texception: " where " = " VAL " (" trim(substr(CMT, index(CMT, ":") + 1)) ")"
		addsec(sec)
		exc[sec] = exc[sec] "\n" trim($0)
		next
	}
	if (EMPTYMARK) {
		print "E\t" FNR "\tunmarked: " where " = " VAL " (the exception marker needs a reason: # exception: <reason>)"
	} else {
		print "E\t" FNR "\tunmarked: " where " = " VAL " (not canonical; add a trailing \"# exception: <reason>\" to keep it)"
	}
	print "N\tdropped " where " (no exception marker)"
}
END {
	if (mode == "block") {
		if (nbegin == 0) print "E\t1\tno full-lint managed block; ./gates sync appends it"
		if (nbegin > 1) print "E\t1\tmore than one full-lint managed block"
		if (nbegin > 0 && !ended) print "E\t" bline "\tthe managed block has no end marker (" end ")"
		if (haspkg && !lintsws) print "E\t1\t[package] does not inherit the workspace lints; add [lints] with workspace = true"
		print "P\t" (haspkg && !haslints ? 1 : 0)
	}
	for (i = 1; i <= nckey && (mode != "block" || nbegin > 0); i++) {
		id = ckeys[i]
		if (!(id in seen)) {
			split(id, parts, SUBSEP)
			print "E\t" (bline ? bline : 1) "\tmissing: [" parts[1] "] " parts[2] " = " canon[id]
		}
	}
	for (i = 1; i <= nsec; i++) {
		s = secorder[i]
		if (i > 1) print "R\t"
		print "R\t[" s "]"
		for (j = 1; j <= nckey; j++) {
			split(ckeys[j], parts, SUBSEP)
			if (parts[1] == s) print "R\t" cline[ckeys[j]]
		}
		n = split(substr(exc[s], 2), lines, "\n")
		for (j = 1; j <= n; j++) print "R\t" lines[j]
	}
}
AWK

drift_records() {
	awk -v mode="$1" -v begin="$DRIFT_BEGIN" -v end="$DRIFT_END" "$DRIFT_AWK" "$2" "$3"
}

# Prints findings for one managed file; returns 1 on any error.
drift_check_file() {
	local mode=$1 file=$2 canon=$3 kind line msg rc=0
	if [[ ! -f "$file" ]]; then
		echo "$file: error: missing; ./gates sync writes it"
		return 1
	fi
	while IFS=$'\t' read -r kind line msg; do
		case "$kind" in
		E)
			echo "$file:$line: error: $msg"
			rc=1
			;;
		W)
			echo "warning: $file:$line: $msg"
			if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
				echo "::warning file=$file,line=$line::$msg"
			fi
			;;
		esac
	done < <(drift_records "$mode" "$canon" "$file")
	return "$rc"
}

drift_sync_file() {
	local mode=$1 file=$2 canon=$3 tmp records b z
	tmp="$(mktemp)"
	if [[ "$mode" == "file" ]]; then
		if [[ -f "$file" ]]; then
			records="$(drift_records file "$canon" "$file")"
		else
			records="$(drift_records file "$canon" /dev/null)"
		fi
		{
			echo "$DRIFT_FILE_HEADER"
			awk -F'\t' '$1 == "R" { sub(/^R\t/, ""); print }' <<<"$records"
		} >"$tmp"
	else
		[[ -f "$file" ]] || : >"$file"
		records="$(drift_records block "$canon" "$file")"
		# Appending a block beside tables of the same name would leave a
		# manifest cargo rejects as a duplicate key.
		if grep -q $'^O\t' <<<"$records"; then
			awk -F'\t' -v f="$file" '$1 == "E" && /outside the managed block/ { print "sync: " f ":" $2 ": error: " $3 }' <<<"$records" >&2
			rm -f "$tmp"
			return 1
		fi
		b="$(awk -F'\t' '$1 == "B" { print $2; exit }' <<<"$records")"
		z="$(awk -F'\t' '$1 == "Z" { print $2; exit }' <<<"$records")"
		{
			if [[ -n "$b" && -n "$z" ]]; then
				head -n "$((b - 1))" "$file"
			else
				cat "$file"
				[[ -s "$file" ]] && echo
			fi
			echo "$DRIFT_BEGIN"
			awk -F'\t' '$1 == "R" { sub(/^R\t/, ""); print }' <<<"$records"
			echo "$DRIFT_END"
			if [[ -n "$b" && -n "$z" ]]; then
				tail -n "+$((z + 1))" "$file"
			fi
			if grep -q $'^P\t1$' <<<"$records"; then
				printf '\n[lints]\nworkspace = true\n'
			fi
		} >"$tmp"
	fi
	awk -F'\t' -v f="$file" '$1 == "N" { print "sync: " f ": " $2 }' <<<"$records"
	if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
		rm -f "$tmp"
		return 0
	fi
	# cat into the existing file keeps its mode and any hard links intact.
	cat "$tmp" >"$file"
	rm -f "$tmp"
	echo "sync: wrote $file"
}

# Pins in the consumer's CI files, one "<lang> <sha>" per distinct pin.
consumer_pins() {
	local files=() f
	for f in .github/workflows/*.yml .gitlab-ci.yml; do
		[[ -f "$f" ]] && files+=("$f")
	done
	[[ ${#files[@]} -gt 0 ]] || return 0
	grep -ohE 'PhillipChaffee/full-lint/\.github/workflows/[a-z]+(-mutation)?\.yml@[0-9a-f]{40}|raw\.githubusercontent\.com/PhillipChaffee/full-lint/[0-9a-f]{40}/gitlab/[a-z]+\.yml' "${files[@]}" |
		sed -E 's#.*/workflows/([a-z]+)(-mutation)?\.yml@([0-9a-f]{40})#\1 \3#; s#.*/full-lint/([0-9a-f]{40})/gitlab/([a-z]+)\.yml#\2 \1#' |
		sort -u || true
}

pin_check() {
	local shas
	shas="$(consumer_pins | awk '{ print $2 }' | sort -u)"
	if [[ -z "$shas" ]]; then
		echo "pins: error: no full-lint pin in .github/workflows/*.yml or .gitlab-ci.yml"
		return 1
	fi
	if [[ "$(wc -l <<<"$shas")" -gt 1 ]]; then
		echo "pins: error: the CI files pin different full-lint commits: $(tr '\n' ' ' <<<"$shas")"
		return 1
	fi
	if [[ "${FULL_LINT_SHA:-local}" != "local" && "$shas" != "$FULL_LINT_SHA" ]]; then
		echo "pins: error: the CI files pin $shas but this run uses $FULL_LINT_SHA"
		return 1
	fi
}

stub_check() {
	if [[ -f gates ]] && ! cmp -s gates "$FULL_LINT_ROOT/consumer/gates"; then
		echo "gates: error: differs from full-lint's consumer/gates; ./gates sync rewrites it"
		return 1
	fi
}

drift_check() {
	local i rc=0
	for i in "${!managed_files[@]}"; do
		drift_check_file "${managed_modes[$i]}" "${managed_files[$i]}" "${managed_canon[$i]}" || rc=1
	done
	pin_check || rc=1
	stub_check || rc=1
	if [[ "$rc" -eq 0 ]]; then
		echo "sync-check: managed files, pins and the gates stub match full-lint"
	fi
	return "$rc"
}

drift_sync() {
	local i rc=0
	for i in "${!managed_files[@]}"; do
		drift_sync_file "${managed_modes[$i]}" "${managed_files[$i]}" "${managed_canon[$i]}" || rc=1
	done
	if [[ -f gates ]] && ! cmp -s gates "$FULL_LINT_ROOT/consumer/gates"; then
		cp "$FULL_LINT_ROOT/consumer/gates" gates
		chmod +x gates
		echo "sync: wrote gates"
	fi
	return "$rc"
}
