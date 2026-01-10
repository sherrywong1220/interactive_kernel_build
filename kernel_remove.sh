#!/usr/bin/env bash
set -euo pipefail

timestamp() {
	date '+%Y-%m-%d %H:%M:%S'
}

log_msg() {
	local level="$1"
	shift
	printf '[%s] [%s] %s\n' "$(timestamp)" "$level" "$*"
}

fatal() {
	log_msg "ERROR" "$1"
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

prompt_non_empty() {
	local prompt="$1"
	local value=""
	while true; do
		read -rp "$prompt" value
		if [[ -n "$value" ]]; then
			printf '%s\n' "$value"
			return
		fi
		echo "Input required. Please try again."
	done
}

detect_kernel_release() {
	local build_dir="$1"
	local release_file="$build_dir/include/config/kernel.release"
	local uts_file="$build_dir/include/generated/utsrelease.h"

	if [[ -f "$release_file" ]]; then
		head -n1 "$release_file"
		return 0
	fi
	if [[ -f "$uts_file" ]]; then
		sed -n 's/^#define UTS_RELEASE "\(.*\)"/\1/p' "$uts_file" | head -n1
		return 0
	fi
	return 1
}

run_rm() {
	local path="$1"
	if [[ ! -e "$path" ]]; then
		return 0
	fi
	if [[ $EUID -eq 0 ]]; then
		rm -rf -- "$path"
	else
		sudo rm -rf -- "$path"
	fi
}

KERNEL_INPUT=$(prompt_non_empty "Linux image name (/boot/vmlinuz-*) or build directory path: ")
KERNEL_BASENAME=$(basename "$KERNEL_INPUT")
KERNEL_MODE="build"

if [[ "$KERNEL_BASENAME" == vmlinuz-* ]]; then
	KERNEL_MODE="image"
	KERNEL_RELEASE="${KERNEL_BASENAME#vmlinuz-}"
else
	KERNEL_BUILD_DIR=$(abs_path "$KERNEL_INPUT")

	[[ -d "$KERNEL_BUILD_DIR" ]] || fatal "Build directory $KERNEL_BUILD_DIR does not exist."
	if [[ "$KERNEL_BUILD_DIR" == "/" ]]; then
		fatal "Refusing to operate on /"
	fi

	if [[ ! -f "$KERNEL_BUILD_DIR/.config" && ! -f "$KERNEL_BUILD_DIR/include/config/kernel.release" ]]; then
		log_msg "WARN" "No .config or kernel.release found in $KERNEL_BUILD_DIR. Proceeding may fail to detect release."
	fi

	KERNEL_RELEASE=$(detect_kernel_release "$KERNEL_BUILD_DIR" || true)
	if [[ -z "${KERNEL_RELEASE:-}" ]]; then
		KERNEL_RELEASE=$(prompt_non_empty "Kernel release string (e.g. 6.8.0-custom): ")
	fi
fi

if [[ -z "${KERNEL_RELEASE:-}" ]]; then
	KERNEL_RELEASE=$(prompt_non_empty "Kernel release string (e.g. 6.8.0-custom): ")
fi

log_msg "INFO" "Kernel release detected: $KERNEL_RELEASE"

read -rp "Proceed to remove installed kernel artifacts for $KERNEL_RELEASE? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
	fatal "Aborting at user request."
fi

BOOT_PATHS=(
	"/boot/vmlinuz-$KERNEL_RELEASE"
	"/boot/System.map-$KERNEL_RELEASE"
	"/boot/config-$KERNEL_RELEASE"
	"/boot/initrd.img-$KERNEL_RELEASE"
	"/boot/initrd.img-$KERNEL_RELEASE.old"
	"/boot/abi-$KERNEL_RELEASE"
	"/boot/retpoline-$KERNEL_RELEASE"
)

log_msg "INFO" "Removing kernel images from /boot"
for path in "${BOOT_PATHS[@]}"; do
	run_rm "$path"
done

log_msg "INFO" "Removing module directory /lib/modules/$KERNEL_RELEASE"
run_rm "/lib/modules/$KERNEL_RELEASE"

log_msg "INFO" "Removing headers if present"
run_rm "/usr/src/linux-headers-$KERNEL_RELEASE"

if [[ "$KERNEL_MODE" == "build" ]]; then
	read -rp "Remove build directory $KERNEL_BUILD_DIR? [y/N]: " remove_build
	if [[ "$remove_build" =~ ^[Yy]$ ]]; then
		log_msg "INFO" "Removing build directory $KERNEL_BUILD_DIR"
		run_rm "$KERNEL_BUILD_DIR"
	fi
fi

log_msg "INFO" "Kernel removal steps completed."
