#!/usr/bin/env bash

# Bun runtime discovery, shared by every Sandwich entrypoint.
#
# A tool manager comes first. Omarchy installs Bun with `mise use -g bun@latest`
# and installs nothing else Bun-related, so the version the machine tracks and
# updates is the manager's copy. A leftover binary inside the Bun prefix's bin
# directory - bun's own installer, or an old `bun upgrade` - must not outrank it:
# that directory doubles as the global bin directory, it holds Sandwich's shims,
# and the Sandwich shell block puts it at the front of PATH. An explicitly
# exported SANDWICH_BUN still wins, because that is the documented override.

sandwich_bun_runtime() {
    local mise_data="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
    local path_bun candidate
    path_bun="$(command -v bun 2>/dev/null || true)"
    for candidate in \
        "${SANDWICH_BUN:-}" \
        "$mise_data/installs/bun/latest/bin/bun" \
        "$mise_data/shims/bun" \
        "$path_bun" \
        "${BUN_INSTALL:-$HOME/.bun}/bin/bun"
    do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        # An unmanaged copy inside the prefix Sandwich shadows only counts when no
        # manager owns Bun; otherwise PATH would resolve the duplicate, not the tool.
        if [[ "$candidate" == "${BUN_INSTALL:-$HOME/.bun}/bin/bun" ]] &&
           [[ -n "$path_bun" && "$path_bun" != "$candidate" ]] &&
           [[ "${SANDWICH_BUN:-}" != "$candidate" ]]; then
            continue
        fi
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

# Labels the runtime origin for Sandwich's doctor and installers.
sandwich_bun_runtime_source() {
    local runtime="$1"
    local mise_data="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
    case "$runtime" in
        "$mise_data/"* | "$HOME/.local/share/mise/"*) printf 'mise\n' ;;
        "${BUN_INSTALL:-$HOME/.bun}/bin/"*) printf 'Bun prefix (unmanaged)\n' ;;
        *) printf 'PATH\n' ;;
    esac
}
