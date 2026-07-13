#!/bin/bash
# Vendor every non-system dylib a binary needs into one directory, and rewrite
# the load paths to point at it.
#
#   bundle-dylibs.sh <frameworks-dir> <binary> [binary ...]
#
# Without this, Tusk links Homebrew's libpq by absolute path (/opt/homebrew/...)
# and dies at launch on any Mac that doesn't happen to have the same Homebrew
# kegs installed. libpq also pulls in openssl@3 and krb5, and those pull in more,
# so the walk has to be recursive.
#
# Layout produced:
#   Frameworks/libpq.5.dylib, libssl.3.dylib, libcrypto.3.dylib, ...
#   executable  ->  @rpath/<name>          (resolved via LC_RPATH, added by caller)
#   dylib->dylib -> @loader_path/<name>    (they all sit in the same directory)
set -euo pipefail

FRAMEWORKS="$1"; shift
BINARIES=("$@")

mkdir -p "$FRAMEWORKS"

# A dep is "ours to vendor" if it's an absolute path outside the OS. Anything in
# /usr/lib or /System ships with macOS and must NOT be copied.
is_vendorable() {
  case "$1" in
    /usr/lib/*|/System/*) return 1 ;;
    /*) return 0 ;;
    *) return 1 ;;  # already @rpath/@loader_path/@executable_path
  esac
}

deps_of() {
  # Skip line 1 (the file itself) and the LC_ID_DYLIB self-reference.
  otool -L "$1" | tail -n +2 | awk '{print $1}'
}

# --- Pass 1: recursively collect ------------------------------------------------
declare -a QUEUE=()
declare -a COLLECTED=()

seen() { local n; for n in "${COLLECTED[@]+"${COLLECTED[@]}"}"; do [[ "$n" == "$1" ]] && return 0; done; return 1; }

for bin in "${BINARIES[@]}"; do QUEUE+=("$bin"); done

while [ ${#QUEUE[@]} -gt 0 ]; do
  current="${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    is_vendorable "$dep" || continue
    base="$(basename "$dep")"
    seen "$base" && continue
    COLLECTED+=("$base")
    cp -L "$dep" "$FRAMEWORKS/$base"     # -L: resolve Homebrew's opt/ symlinks
    chmod u+w "$FRAMEWORKS/$base"
    QUEUE+=("$FRAMEWORKS/$base")          # recurse: this dylib has deps too
    echo "  vendored $base"
  done < <(deps_of "$current")
done

if [ ${#COLLECTED[@]} -eq 0 ]; then
  echo "  nothing to vendor (already self-contained)"
  exit 0
fi

# --- Pass 2: rewrite load paths -------------------------------------------------
# install_name_tool invalidates the code signature, so every touched Mach-O gets
# re-signed ad-hoc afterwards. On Apple Silicon an invalid signature is fatal:
# dyld refuses to load the image at all.
for base in "${COLLECTED[@]}"; do
  lib="$FRAMEWORKS/$base"
  install_name_tool -id "@rpath/$base" "$lib" 2>/dev/null
  while IFS= read -r dep; do
    is_vendorable "$dep" || continue
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$lib" 2>/dev/null
  done < <(deps_of "$lib")
  codesign --force --sign - "$lib" 2>/dev/null
done

for bin in "${BINARIES[@]}"; do
  while IFS= read -r dep; do
    is_vendorable "$dep" || continue
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$bin" 2>/dev/null
  done < <(deps_of "$bin")
done

echo "  vendored ${#COLLECTED[@]} dylib(s) into $FRAMEWORKS"
