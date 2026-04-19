#!/bin/bash
# perf-cpus.sh
# Display current CPU scaling governor and frequency in a table,
# then prompt whether to apply the `performance` governor to all CPUs
# or a selected subset.

set -euo pipefail

SYS_CPU_DIR=/sys/devices/system/cpu

print_table() {
	printf "%-6s  %-12s  %-12s\n" "CPU" "Governor" "CurFreq(kHz)"
	printf "%-6s  %-12s  %-12s\n" "----" "---------" "------------"
	for cpu_dir in ${SYS_CPU_DIR}/cpu[0-9]*; do
		cpu_name=$(basename "${cpu_dir}")
		gov_file="${cpu_dir}/cpufreq/scaling_governor"
		freq_file="${cpu_dir}/cpufreq/scaling_cur_freq"
		if [ -r "${gov_file}" ]; then
			gov=$(cat "${gov_file}" 2>/dev/null || echo "n/a")
		else
			gov="n/a"
		fi
		if [ -r "${freq_file}" ]; then
			freq=$(cat "${freq_file}" 2>/dev/null || echo "n/a")
		else
			freq="n/a"
		fi
		printf "%-6s  %-12s  %-12s\n" "${cpu_name}" "${gov}" "${freq}"
	done
}

apply_governor() {
	local target_gov="$1"
	shift
	local targets=("$@")
	local failed=0
	for cpu in "${targets[@]}"; do
		gov_file="${SYS_CPU_DIR}/${cpu}/cpufreq/scaling_governor"
		if [ ! -w "${gov_file}" ]; then
			echo "Skipping ${cpu}: cannot write ${gov_file} (permission or missing cpufreq)" >&2
			failed=1
			continue
		fi
		if ! echo "${target_gov}" > "${gov_file}" 2>/dev/null; then
			echo "Failed to write ${target_gov} to ${gov_file}" >&2
			failed=1
		else
			echo "Wrote ${target_gov} to ${cpu}"
		fi
	done
	return ${failed}
}

list_cpus() {
	cpus=()
	for cpu_dir in ${SYS_CPU_DIR}/cpu[0-9]*; do
		cpus+=("$(basename "${cpu_dir}")")
	done
	printf "%s\n" "${cpus[@]}"
}

parse_cpu_selection() {
	# Accept forms like: 0,1,3-5
	local input="$1"
	local -a out=()
	IFS=',' read -ra parts <<< "${input}"
	for p in "${parts[@]}"; do
		if [[ "${p}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
			start=${BASH_REMATCH[1]}
			end=${BASH_REMATCH[2]}
			for ((i=start; i<=end; i++)); do
				out+=("cpu${i}")
			done
		elif [[ "${p}" =~ ^[0-9]+$ ]]; then
			out+=("cpu${p}")
		fi
	done
	# remove duplicates
	echo "${out[@]}" | tr ' ' '\n' | awk '!seen[$0]++'
}

echo "Current CPU scaling governors and frequencies:"
print_table

read -r -p $'Apply the "performance" governor to ALL CPUs? [y/N]: ' ans
case "${ans,,}" in
	y|yes)
		targets=($(list_cpus))
		;;
	n|no|"")
		read -r -p $'Enter CPU numbers or ranges (e.g. 0,1,3-5) or Q to quit: ' sel
		if [[ "${sel,,}" = q || "${sel,,}" = quit ]]; then
			echo "Aborting. No changes made."
			exit 0
		fi
		# parse selection
		mapfile -t targets < <(parse_cpu_selection "${sel}")
		if [ ${#targets[@]} -eq 0 ]; then
			echo "No valid CPUs parsed from '${sel}'. Exiting." >&2
			exit 2
		fi
		;;
	*)
		echo "Unknown response. Aborting." >&2
		exit 2
		;;
esac

echo
echo "Applying 'performance' governor to: ${targets[*]}"
apply_governor performance "${targets[@]}"

echo
echo "Verification after change:"
print_table
