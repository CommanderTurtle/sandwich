# >>> sandwich >>>
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export BUN_INSTALL_BIN="${BUN_INSTALL_BIN:-$BUN_INSTALL/bin}"
export BUN_INSTALL_GLOBAL_DIR="${BUN_INSTALL_GLOBAL_DIR:-$BUN_INSTALL/install/global}"
export DO_NOT_TRACK=1

sandwich_prepend_path() {
    case ":$PATH:" in
        *)
            local entry updated=""
            local -a entries
            IFS=: read -r -a entries <<<"$PATH"
            for entry in "${entries[@]}"; do
                [[ "$entry" == "$1" ]] && continue
                updated="${updated:+$updated:}$entry"
            done
            PATH="$1${updated:+:$updated}"
            ;;
    esac
}
sandwich_prepend_path "$BUN_INSTALL_BIN"
sandwich_prepend_path "$HOME/.local/bin"
export PATH
unset -f sandwich_prepend_path

# Sudo runs its command through sudoers' secure_path, which never sees the two
# directories above, so `sudo sandwich` would not resolve. Pass the PATH that
# already works instead of editing root's sudoers.
sudo() {
    command sudo env PATH="$PATH" "$@"
}
# <<< sandwich <<<
