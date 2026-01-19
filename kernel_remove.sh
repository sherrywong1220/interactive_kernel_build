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
	echo ""
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

find_build_dir_from_modules() {
	local kernel_release="$1"
	local modules_dir="/lib/modules/$kernel_release"
	local build_link="$modules_dir/build"
	local source_link="$modules_dir/source"

	if [[ -L "$build_link" ]]; then
		local target
		target=$(readlink -f "$build_link" 2>/dev/null || readlink "$build_link" 2>/dev/null)
		if [[ -n "$target" && -d "$target" ]]; then
			abs_path "$target"
			return 0
		fi
	fi

	if [[ -L "$source_link" ]]; then
		local target
		target=$(readlink -f "$source_link" 2>/dev/null || readlink "$source_link" 2>/dev/null)
		if [[ -n "$target" && -d "$target" ]]; then
			abs_path "$target"
			return 0
		fi
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

echo ""
color_cyan "🗑️  "
color_cyan "Kernel Removal Tool"
echo ""

KERNEL_INPUT=$(prompt_non_empty "$(color_cyan "📁 Linux image name (/boot/vmlinuz-*) or build directory path: ")" )
KERNEL_BASENAME=$(basename "$KERNEL_INPUT")
KERNEL_MODE="build"

if [[ "$KERNEL_BASENAME" == vmlinuz-* ]]; then
	KERNEL_MODE="image"
	KERNEL_RELEASE="${KERNEL_BASENAME#vmlinuz-}"
	if KERNEL_BUILD_DIR=$(find_build_dir_from_modules "$KERNEL_RELEASE" 2>/dev/null); then
		color_green "✓ "
		log_msg "INFO" "Found build directory from /lib/modules: $KERNEL_BUILD_DIR"
	else
		color_yellow "⚠️  "
		log_msg "INFO" "Could not find build directory from /lib/modules for $KERNEL_RELEASE"
		echo ""
		color_cyan "📋 Details of /lib/modules/$KERNEL_RELEASE:"
		echo ""
		modules_dir="/lib/modules/$KERNEL_RELEASE"
		if [[ -d "$modules_dir" ]]; then
			color_cyan "  Directory exists: $modules_dir"
			echo ""
			color_cyan "  Contents:"
			if [[ $EUID -eq 0 ]]; then
				ls -la "$modules_dir" 2>/dev/null | head -20 || echo "    (Unable to list contents)"
			else
				sudo ls -la "$modules_dir" 2>/dev/null | head -20 || echo "    (Unable to list contents)"
			fi
			echo ""
			build_link="$modules_dir/build"
			source_link="$modules_dir/source"
			if [[ -L "$build_link" ]]; then
				build_target=$(readlink -f "$build_link" 2>/dev/null || readlink "$build_link" 2>/dev/null)
				color_yellow "  build link: $build_link -> $build_target"
				if [[ ! -d "$build_target" ]]; then
					color_red "    (target directory does not exist)"
				fi
			else
				color_yellow "  build link: $build_link (not found or not a symlink)"
			fi
			if [[ -L "$source_link" ]]; then
				source_target=$(readlink -f "$source_link" 2>/dev/null || readlink "$source_link" 2>/dev/null)
				color_yellow "  source link: $source_link -> $source_target"
				if [[ ! -d "$source_target" ]]; then
					color_red "    (target directory does not exist)"
				fi
			else
				color_yellow "  source link: $source_link (not found or not a symlink)"
			fi
		else
			color_red "  Directory does not exist: $modules_dir"
			echo ""
			color_cyan "  Available kernel modules directories:"
			if [[ $EUID -eq 0 ]]; then
				ls -1d /lib/modules/*/ 2>/dev/null | sed 's|/$||' | sed 's|^|    |' || echo "    (Unable to list)"
			else
				sudo ls -1d /lib/modules/*/ 2>/dev/null | sed 's|/$||' | sed 's|^|    |' || echo "    (Unable to list)"
			fi
		fi
		echo ""
		KERNEL_BUILD_DIR=""
	fi
else
	KERNEL_BUILD_DIR=$(abs_path "$KERNEL_INPUT")

	[[ -d "$KERNEL_BUILD_DIR" ]] || fatal "Build directory $KERNEL_BUILD_DIR does not exist."
	if [[ "$KERNEL_BUILD_DIR" == "/" ]]; then
		fatal "Refusing to operate on /"
	fi

	if [[ ! -f "$KERNEL_BUILD_DIR/.config" && ! -f "$KERNEL_BUILD_DIR/include/config/kernel.release" ]]; then
		color_yellow "⚠️  "
		log_msg "WARN" "No .config or kernel.release found in $KERNEL_BUILD_DIR. Proceeding may fail to detect release."
	fi

	KERNEL_RELEASE=$(detect_kernel_release "$KERNEL_BUILD_DIR" || true)
	if [[ -z "${KERNEL_RELEASE:-}" ]]; then
		KERNEL_RELEASE=$(prompt_non_empty "$(color_cyan "🏷️  Kernel release string (e.g. 6.8.0-custom): ")" )
	fi
fi

if [[ -z "${KERNEL_RELEASE:-}" ]]; then
	KERNEL_RELEASE=$(prompt_non_empty "$(color_cyan "🏷️  Kernel release string (e.g. 6.8.0-custom): ")" )
fi

color_green "✓ "
log_msg "INFO" "Kernel release detected: $KERNEL_RELEASE"

echo ""
read -rp "$(color_yellow "⚠️  Proceed to remove installed kernel artifacts for $(color_cyan "$KERNEL_RELEASE")? [y/N]: ")" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
	fatal "Aborting at user request."
fi
echo ""

BOOT_PATHS=(
	"/boot/vmlinuz-$KERNEL_RELEASE"
	"/boot/System.map-$KERNEL_RELEASE"
	"/boot/config-$KERNEL_RELEASE"
	"/boot/initrd.img-$KERNEL_RELEASE"
	"/boot/initrd.img-$KERNEL_RELEASE.old"
	"/boot/abi-$KERNEL_RELEASE"
	"/boot/retpoline-$KERNEL_RELEASE"
)

color_blue "🗑️  "
log_msg "INFO" "Removing kernel images from /boot"
for path in "${BOOT_PATHS[@]}"; do
	run_rm "$path"
done

color_blue "🗑️  "
log_msg "INFO" "Removing module directory /lib/modules/$KERNEL_RELEASE"
run_rm "/lib/modules/$KERNEL_RELEASE"

color_blue "🗑️  "
log_msg "INFO" "Removing headers if present"
run_rm "/usr/src/linux-headers-$KERNEL_RELEASE"

if [[ -n "${KERNEL_BUILD_DIR:-}" && -d "$KERNEL_BUILD_DIR" ]]; then
	if [[ "$KERNEL_BUILD_DIR" == "/" ]]; then
		log_msg "WARN" "Refusing to remove root directory. Skipping build directory removal."
	else
		echo ""
		color_red "⚠️  "
		color_yellow "WARNING: "
		color_cyan "This operation will permanently delete the build directory!"
		echo ""
		printf '%s\n' "$(color_yellow "Build directory:") $(color_cyan "$KERNEL_BUILD_DIR")"
		echo ""
		read -rp "$(color_red "⚠️  Remove build directory $KERNEL_BUILD_DIR? [y/N]: ")" remove_build
		if [[ "$remove_build" =~ ^[Yy]$ ]]; then
			log_msg "INFO" "Removing build directory $KERNEL_BUILD_DIR"
			run_rm "$KERNEL_BUILD_DIR"
			color_green "✓ Build directory removed successfully"
			echo ""
		else
			color_yellow "⚠️  Build directory removal cancelled by user"
			echo ""
		fi
	fi
fi

echo ""
color_green "✓ "
log_msg "INFO" "Kernel removal steps completed."
color_green "🎉 "
color_green "All kernel artifacts have been removed successfully!"
echo ""
