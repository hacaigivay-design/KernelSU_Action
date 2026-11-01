#!/usr/bin/env bash
# Prepare the defconfig and compile the kernel.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/kernelsu.sh
. "$(dirname "${BASH_SOURCE[0]}")/kernelsu.sh"
# shellcheck source=scripts/patches.sh
. "$(dirname "${BASH_SOURCE[0]}")/patches.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

# ------------------------------------------------------------- defconfig ---

prepare_defconfig() {
	group "Preparing defconfig"
	[ -f "$DEFCONFIG_PATH" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
       Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"

	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU
		ksu_hook_configs "${KSU_VARIANT}" "${KSU_HOOK_MODE:-auto}" "$DEFCONFIG_PATH" "$kver"

		if is_true "${ENABLE_SUSFS:-false}"; then
			susfs_defconfig "$DEFCONFIG_PATH"
		fi

		if is_true "${ENABLE_KPM:-false}"; then
			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KPM=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y
		fi
	fi

	is_true "${ADD_OVERLAYFS_CONFIG:-false}" && kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS

	if is_true "${ADD_KPROBES_CONFIG:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_MODULES=y CONFIG_KPROBES=y CONFIG_HAVE_KPROBES=y CONFIG_KPROBE_EVENTS=y
	fi

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n CONFIG_THINLTO=n CONFIG_LTO_NONE=y
	fi

	is_true "${DISABLE_CC_WERROR:-false}" && kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR

	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "$DEFCONFIG_PATH" "${kv%%=*}" "${kv#*=}" ;;
				*)   warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)" ;;
			esac
		done
	fi

	if [ -n "${KERNEL_NAME:-}" ]; then
		kconf_set "$DEFCONFIG_PATH" CONFIG_LOCALVERSION "\"-${KERNEL_NAME}\""
		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
			sed -i 's/echo "\$res"/echo "\$res"/; s/-dirty//g' "${KERNEL_DIR}/scripts/setlocalversion"
		fi
	fi

	info "defconfig changes:"
	diff -u "${WORKSPACE}/defconfig.orig" "$DEFCONFIG_PATH" | sed -n '4,$p' | sed 's/^/    /' || true
	endgroup
}

# ----------------------------------------------------------------- build ---

# Strip any KCFLAGS=... token from a free-form string.
# This was the original cause of "-DKBUILD_BASENAME flashlight_core" errors.
_strip_kcflags() {
	printf '%s' "$1" | sed -E 's/(^|[[:space:]])[^[:space:]]*KCFLAGS=[^[:space:]]*//g' \
		| sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

make_args() {
	printf '%s' "O=out ARCH=${ARCH}"
	if [ -n "${CUSTOM_CMDS:-}" ]; then
		local c
		c=$(_strip_kcflags "$CUSTOM_CMDS")
		[ -n "$c" ] && printf ' %s' "$c"
	fi
	if [ -n "${EXTRA_CMDS:-}" ]; then
		local e
		e=$(_strip_kcflags "$EXTRA_CMDS")
		[ -n "$e" ] && printf ' %s' "$e"
	fi
	[ -n "${GCC_64:-}" ] && printf ' %s' "$GCC_64"
	[ -n "${GCC_32:-}" ] && printf ' %s' "$GCC_32"
	if is_true "${USE_LLVM:-false}"; then
		printf ' LLVM=1 LLVM_IAS=1'
		[ -n "${GCC_64:-}" ] || printf ' CROSS_COMPILE=aarch64-linux-gnu-'
	fi
}

_dump_first_error() {
	local log=$1
	echo "================================================================"
	echo "===== BUILD FAILED -- FIRST ERROR CONTEXT ====="
	echo "================================================================"
	if [ ! -f "$log" ]; then
		echo "(no log file at ${log})"
		return 0
	fi
	local first
	first=$(grep -n -m1 -E "(^|[^a-zA-Z])error:|undefined reference|fatal error:" "$log" | cut -d: -f1 || true)
	if [ -z "${first:-}" ]; then
		echo "(no 'error:' line found -- dumping last 120 lines)"
		tail -n 120 "$log"
		return 0
	fi
	local start end
	start=$(( first > 30 ? first - 30 : 1 ))
	end=$(( first + 15 ))
	echo ">>> first error at line ${first}; showing ${start}..${end}"
	sed -n "${start},${end}p" "$log"
	echo "================================================================"
}

# Patch scripts/Makefile.build + root Makefile so -DKBUILD_BASENAME is quoted.
# This is the REAL fix for "macro name must be an identifier".
# Idempotent: safe to run multiple times.
_patch_kbuild_basename() {
	local dir=$1
	local changed=0
	for f in "${dir}/scripts/Makefile.build" "${dir}/Makefile"; do
		[ -f "$f" ] || continue
		if grep -q -- '-DKBUILD_BASENAME=\$(KBUILD_BASENAME)' "$f" 2>/dev/null; then
			# Replace unquoted form with quoted form
			sed -i -E "s|-DKBUILD_BASENAME=\\\$\(KBUILD_BASENAME\)|-DKBUILD_BASENAME='\"\$(KBUILD_BASENAME)\"'|g" "$f"
			changed=1
			info "patched KBUILD_BASENAME quoting in $f"
		fi
	done
	if [ "$changed" = "1" ]; then
		ok "KBUILD_BASENAME quoting patched"
	else
		info "KBUILD_BASENAME already quoted (or pattern not found)"
	fi
}

build_kernel() {
	group "Building kernel"
	export PATH="${CLANG_PATH:-}:${PATH}"
	export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}
	export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-kernelsu-action}

	unset DISABLE_LTO
	unset KCFLAGS || true

	if [ -n "${KSU_EXPECTED_SIZE:-}" ] && [ -n "${KSU_EXPECTED_HASH:-}" ]; then
		export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"
	fi

	# ---------- FIX ROOT CAUSE: quote -DKBUILD_BASENAME in kernel ----------
	# Old MTK trees emit `-DKBUILD_BASENAME=$(KBUILD_BASENAME)` unquoted, which
	# clang rejects as "macro name must be an identifier" when KBUILD_BASENAME
	# is `flashlight_core`. This is independent of any env var; patching the
	# kernel Makefile is the only reliable fix.
	_patch_kbuild_basename "$KERNEL_DIR"

	local cc="clang" args
	args=$(make_args)
	if is_true "${ENABLE_CCACHE:-true}" && command -v ccache >/dev/null; then
		cc="ccache clang"
		export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"
		info "ccache enabled (dir: ${CCACHE_DIR})"
	fi

	local jobs vflag log
	jobs="$(nproc --all)"
	vflag=""
	log="${WORKSPACE}/build.log"
	if [ "${DEBUG_BUILD:-0}" = "1" ]; then
		jobs="1"
		vflag="V=1"
		info "DEBUG_BUILD=1: serial build (-j1 V=1), log -> ${log}"
	else
		info "parallel build (-j${jobs}), log -> ${log}"
	fi

	cd "$KERNEL_DIR"

	info "=== make args dump ==="
	info "args: ${args}"
	info "CC: ${cc}"
	info "KCFLAGS: ${KCFLAGS:-<unset>}"
	info "GCC_64: ${GCC_64:-<unset>}"
	info "GCC_32: ${GCC_32:-<unset>}"

	info "make ${args} ${KERNEL_CONFIG}"
	# shellcheck disable=SC2086
	if ! make -j"${jobs}" ${vflag} CC=clang $args KCFLAGS= "${KERNEL_CONFIG}" 2>&1 | tee "$log"; then
		_dump_first_error "$log"
		die "defconfig generation failed"
	fi

	info "make ${args}"
	# shellcheck disable=SC2086
	if ! make -j"${jobs}" ${vflag} CC="$cc" $args KCFLAGS= 2>&1 | tee -a "$log"; then
		_dump_first_error "$log"
		die "kernel build failed"
	fi

	endgroup
}

# --------------------------------------------------------------- verify ---

check_output() {
	group "Checking build output"
	local boot="${OUT}/arch/${ARCH}/boot"
	local image="${boot}/${KERNEL_IMAGE_NAME}"

	[ -f "$image" ] || die "expected kernel image not found: ${image}
       Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')
       Check that KERNEL_IMAGE_NAME matches what your kernel produces."

	ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "$image" | cut -f1))"
	export_env CHECK_FILE_IS_OK true

	if is_true "${NEED_DTBO:-false}"; then
		[ -f "${boot}/dtbo.img" ] || die "NEED_DTBO=true but ${boot}/dtbo.img was not produced"
		export_env CHECK_DTBO_IS_OK true
		ok "dtbo.img present"
	fi

	if is_true "${ENABLE_KPM:-false}"; then
		kpm_patch_image "$image"
	fi

	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel
		rel=$(sed -nE 's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' "${OUT}/include/generated/utsrelease.h")
		export_env KERNEL_RELEASE "$rel"
		ok "kernel release: ${rel}"
		summary "| Kernel release | \`${rel}\` |"
	fi
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		defconfig) prepare_defconfig ;;
		compile)   build_kernel ;;
		check)     check_output ;;
		all)       prepare_defconfig; build_kernel; check_output ;;
		*) die "unknown build step '$1'" ;;
	esac
fi
