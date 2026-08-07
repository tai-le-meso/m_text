#!/bin/sh
# Installs the `mtext` command somewhere that does not need admin rights, and puts that
# directory on PATH by editing the shell profile.
#
# `/usr/local/bin` is the traditional spot and is unwritable on a managed (MDM) Mac —
# `install` fails with "Permission denied" and there is no sudo to reach for. `~/.local/bin`
# is per-user, needs no privileges, and is already conventional.
#
# Usage:  Tools/install-cli.sh [--prefix DIR] [--no-profile] [--uninstall]
set -eu

PREFIX="${PREFIX:-$HOME/.local}"
EDIT_PROFILE=1
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#--prefix=}"; shift ;;
        --no-profile) EDIT_PROFILE=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "install-cli: unknown option $1" >&2; exit 2 ;;
    esac
done

BIN_DIR="$PREFIX/bin"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Markers make the profile edit idempotent and removable — appending a bare export line
# would stack a new copy on every install and leave nothing to uninstall.
BEGIN_MARK="# >>> m_text >>>"
END_MARK="# <<< m_text <<<"

profile_for_shell() {
    case "$(basename "${SHELL:-/bin/zsh}")" in
        zsh)  printf '%s' "$HOME/.zshrc" ;;
        bash)
            # macOS Terminal starts bash as a *login* shell, which reads .bash_profile and
            # never .bashrc — so .bashrc alone would appear to do nothing.
            if [ -f "$HOME/.bash_profile" ]; then printf '%s' "$HOME/.bash_profile"
            else printf '%s' "$HOME/.profile"; fi ;;
        fish) printf '%s' "$HOME/.config/fish/config.fish" ;;
        *)    printf '%s' "$HOME/.profile" ;;
    esac
}

path_line() {
    case "$(basename "${SHELL:-/bin/zsh}")" in
        fish) printf 'fish_add_path %s\n' "$BIN_DIR" ;;
        *)    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
    esac
}

remove_block() {
    profile="$1"
    [ -f "$profile" ] || return 0
    grep -qF "$BEGIN_MARK" "$profile" || return 0
    tmp=$(mktemp)
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 == b {skip = 1} skip == 0 {print} $0 == e {skip = 0}
    ' "$profile" > "$tmp"
    cat "$tmp" > "$profile"
    rm -f "$tmp"
}

if [ "$UNINSTALL" = "1" ]; then
    rm -f "$BIN_DIR/mtext"
    echo "Removed $BIN_DIR/mtext"
    profile=$(profile_for_shell)
    remove_block "$profile"
    echo "Removed the PATH block from $profile (if it was there)"
    echo "Open a new terminal for it to take effect."
    exit 0
fi

mkdir -p "$BIN_DIR"
install -m 0755 "$SCRIPT_DIR/mtext" "$BIN_DIR/mtext"
echo "Installed $BIN_DIR/mtext"

case ":$PATH:" in
    *":$BIN_DIR:"*)
        echo "$BIN_DIR is already on your PATH — run: mtext ."
        exit 0 ;;
esac

if [ "$EDIT_PROFILE" = "0" ]; then
    echo "$BIN_DIR is not on your PATH. Add it yourself with:"
    echo "  $(path_line)"
    exit 0
fi

profile=$(profile_for_shell)
mkdir -p "$(dirname "$profile")"
remove_block "$profile"          # replace any previous block rather than stacking one
{
    printf '%s\n' "$BEGIN_MARK"
    path_line
    printf '%s\n' "$END_MARK"
} >> "$profile"

echo "Added $BIN_DIR to your PATH in $profile"
echo
echo "Open a new terminal, or run:  . $profile"
echo "Then:  mtext ."
