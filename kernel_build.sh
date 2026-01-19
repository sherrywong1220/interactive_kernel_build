#!/usr/bin/env bash
set -uo pipefail

DEFAULT_LOCALVERSION="-autonuma-eBPF-010726"
START_DIR=$(pwd)
LOG_FILE="${LOG_FILE:-${START_DIR}/kernel_build_$(date +%Y%m%d_%H%M%S).log}"

timestamp() {
	date '+%Y-%m-%d %H:%M:%S'
}

log_msg() {
	local level="$1"
	shift
	local msg="[$(timestamp)] [$level] $*"
	echo "$msg" | tee -a "$LOG_FILE"
}

color_supported() {
	[[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1
}

color_red() {
	if color_supported; then
		printf '\033[1;31m%s\033[0m' "$*"
	else
		printf '%s' "$*"
	fi
}

color_yellow() {
	if color_supported; then
		printf '\033[1;33m%s\033[0m' "$*"
	else
		printf '%s' "$*"
	fi
}

color_green() {
	if color_supported; then
		printf '\033[1;32m%s\033[0m' "$*"
	else
		printf '%s' "$*"
	fi
}

color_cyan() {
	if color_supported; then
		printf '\033[1;36m%s\033[0m' "$*"
	else
		printf '%s' "$*"
	fi
}

color_blue() {
	if color_supported; then
		printf '\033[1;34m%s\033[0m' "$*"
	else
		printf '%s' "$*"
	fi
}

fatal() {
	log_msg "ERROR" "$1"
	color_red "❌ "
	color_red "ERROR: $1"
	echo ""
	exit 1
}

abs_path() {
	local target="$1"
	if command -v realpath >/dev/null 2>&1; then
		realpath -m "$target"
	else
		python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$target"
	fi
}

resolve_relative_to() {
	local base="$1"
	local path_input="$2"
	if [[ "$path_input" = /* ]]; then
		abs_path "$path_input"
	else
		(
			cd "$base" >/dev/null 2>&1 || exit 1
			abs_path "$path_input"
		)
	fi
}

prompt_non_empty() {
	local prompt="$1"
	local value=""
	while true; do
		read -rp "$prompt" value
		if [[ -n "$value" ]]; then
			printf '%s\n' "$value"
			return
		fi
		color_yellow "⚠️  Input required. Please try again."
		echo ""
	done
}

prepare_log() {
	mkdir -p "$(dirname "$LOG_FILE")" || fatal "Unable to create log directory for $LOG_FILE"
	: >"$LOG_FILE" || fatal "Unable to write to $LOG_FILE"
	color_cyan "📝 "
	log_msg "INFO" "Logging build output to $LOG_FILE"
}

run_cmd() {
	local desc="$1"
	shift
	local requires_tty=0
	if [[ "$1" == "--tty" ]]; then
		requires_tty=1
		shift
	fi
	if [[ $# -eq 0 ]]; then
		fatal "run_cmd invoked without a command for: $desc"
	fi
	local cmd_display
	printf -v cmd_display '%q ' "$@"
	cmd_display=${cmd_display% }
	log_msg "INFO" "$desc"
	log_msg "INFO" "Command: $cmd_display"
	if ((requires_tty)); then
		command -v script >/dev/null 2>&1 || fatal "The 'script' utility is required for interactive command logging."
		local tmp_log
		tmp_log=$(mktemp) || fatal "Failed to create temporary log file"
		if script -q -f "$tmp_log" -c "$cmd_display"; then
			grep -Ev '^Script (started|done) on ' "$tmp_log" >>"$LOG_FILE"
			rm -f "$tmp_log"
			color_green "✓ "
			log_msg "INFO" "Completed: $desc"
		else
			grep -Ev '^Script (started|done) on ' "$tmp_log" >>"$LOG_FILE"
			rm -f "$tmp_log"
			color_red "❌ "
			log_msg "ERROR" "Command failed: $desc"
			exit 1
		fi
	else
		if "$@" 2>&1 | tee -a "$LOG_FILE"; then
			color_green "✓ "
			log_msg "INFO" "Completed: $desc"
		else
			color_red "❌ "
			log_msg "ERROR" "Command failed: $desc"
			exit 1
		fi
	fi
}

directory_has_content() {
	local dir="$1"
	if [[ ! -d "$dir" ]]; then
		return 1
	fi
	find "$dir" -mindepth 1 -print -quit >/dev/null 2>&1
}

prepare_log

echo ""
color_blue "🚀 "
color_cyan "Starting kernel build process..."
echo ""

KERNEL_SRC_INPUT=$(prompt_non_empty "$(color_cyan "📁 Kernel source directory path: ")" )
KERNEL_SRC=$(abs_path "$KERNEL_SRC_INPUT")
[[ -d "$KERNEL_SRC" ]] || fatal "Kernel source directory $KERNEL_SRC does not exist"
[[ -f "$KERNEL_SRC/Makefile" ]] || fatal "No Makefile found in $KERNEL_SRC. Please provide a valid kernel tree."
color_green "✓ "
log_msg "INFO" "Kernel source: $KERNEL_SRC"

BUILD_DIR_INPUT=$(prompt_non_empty "$(color_cyan "📦 Build directory (absolute or relative to the kernel source): ")" )
if [[ "$BUILD_DIR_INPUT" = /* ]]; then
	LINUX_BUILD_DIR=$(abs_path "$BUILD_DIR_INPUT")
else
	LINUX_BUILD_DIR=$(resolve_relative_to "$KERNEL_SRC" "$BUILD_DIR_INPUT")
fi
color_green "✓ "
log_msg "INFO" "Requested build directory: $LINUX_BUILD_DIR"

if directory_has_content "$LINUX_BUILD_DIR"; then
	echo ""
	color_yellow "⚠️  "
	read -rp "$(color_yellow "Build directory is not empty. Reuse existing contents? [y/N]: ")" reuse_answer
	if [[ ! "$reuse_answer" =~ ^[Yy]$ ]]; then
		fatal "Aborting at user request."
	fi
	echo ""
fi

read -rp "$(color_cyan "⚙️  Parallel build jobs for make (-j) [20]: ")" jobs_input
JOBS=${jobs_input:-20}
if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -le 0 ]]; then
	fatal "Invalid parallel job count: $JOBS"
fi
color_green "✓ "
log_msg "INFO" "Parallel jobs: $JOBS"

read -rp "$(color_cyan "🏷️  CONFIG_LOCALVERSION (without quotes) [$DEFAULT_LOCALVERSION]: ")" localversion_input
localversion_input=${localversion_input:-$DEFAULT_LOCALVERSION}
localversion_input=${localversion_input%\"}
localversion_input=${localversion_input#\"}
CONFIG_LOCAL_VERSION=${localversion_input:-$DEFAULT_LOCALVERSION}
color_green "✓ "
log_msg "INFO" "CONFIG_LOCALVERSION target: $CONFIG_LOCAL_VERSION"

cd "$KERNEL_SRC" || fatal "Unable to enter $KERNEL_SRC"

export LINUX_BUILD_DIR
log_msg "INFO" "Environment exported: LINUX_BUILD_DIR=$LINUX_BUILD_DIR"

echo ""
color_blue "🔧 "
color_cyan "Preparing build environment..."
echo ""

run_cmd "Show LINUX_BUILD_DIR" bash -c 'echo "$LINUX_BUILD_DIR"'
run_cmd "Create (or confirm) build directory" mkdir -p "$LINUX_BUILD_DIR"
run_cmd "make mrproper" make mrproper
run_cmd "make olddefconfig" make O="$LINUX_BUILD_DIR" olddefconfig

CONFIG_FILE="$LINUX_BUILD_DIR/.config"
[[ -f "$CONFIG_FILE" ]] || fatal "Missing $CONFIG_FILE after olddefconfig. Cannot continue."

echo ""
color_blue "⚙️  "
color_yellow "When menuconfig opens, ensure CONFIG_LOCALVERSION is set to \"$CONFIG_LOCAL_VERSION\"."
echo ""
log_msg "INFO" "When menuconfig opens, ensure CONFIG_LOCALVERSION is set to \"$CONFIG_LOCAL_VERSION\"."
run_cmd "make menuconfig" --tty make O="$LINUX_BUILD_DIR" menuconfig

run_cmd "Set CONFIG_LOCALVERSION" ./scripts/config --file "$CONFIG_FILE" --set-str CONFIG_LOCALVERSION "$CONFIG_LOCAL_VERSION"
run_cmd "Verify CONFIG_LOCALVERSION" bash -c "grep '^CONFIG_LOCALVERSION' '$CONFIG_FILE'"

echo ""
color_blue "🔨 "
color_cyan "Starting kernel build (this may take a while)..."
echo ""

run_cmd "Build kernel (make -j$JOBS -s)" make O="$LINUX_BUILD_DIR" -j"$JOBS" -s

echo ""
color_blue "📥 "
color_cyan "Installing kernel and modules..."
echo ""

run_cmd "Install modules (sudo make modules_install)" sudo make INSTALL_MOD_STRIP=1 O="$LINUX_BUILD_DIR" modules_install
run_cmd "Install kernel (sudo make install)" sudo make O="$LINUX_BUILD_DIR" install
run_cmd "Update GRUB" sudo update-grub
run_cmd "Show updated /boot/grub/grub.cfg" sudo cat /boot/grub/grub.cfg

echo ""
color_green "🎉 "
color_green "Kernel build and installation completed successfully!"
echo ""
log_msg "INFO" "Kernel build and installation steps completed successfully."
log_msg "INFO" "All command output was recorded in $LOG_FILE"
