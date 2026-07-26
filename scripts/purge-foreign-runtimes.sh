#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
mode=check
confirmation=""

usage() {
    cat <<'EOF'
Usage: scripts/purge-foreign-runtimes.sh [--check]
       scripts/purge-foreign-runtimes.sh --apply --confirm PURGE-FOREIGN-JS

Audit or explicitly remove Debian-packaged Node tooling and known user-scoped
Node managers. Sandwich and Bun are never removed. The default is read-only.
EOF
}

while (($#)); do
    case "$1" in
        --check) mode=check ;;
        --apply) mode=apply ;;
        --confirm)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            confirmation="$2"
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'sandwich: unknown purge option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

commands=(node npm npx pnpm yarn corepack)
user_candidates=(
    "$HOME/.nvm"
    "$HOME/.npm-global"
    "$HOME/.pnpm-store"
    "$HOME/.local/share/pnpm"
    "$HOME/.yarn"
    "$HOME/.node-gyp"
)
installed_packages=()
foreign_commands=()
foreign_paths=()
present_user_roots=()

for name in "${commands[@]}"; do
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        resolved="$(readlink -f -- "$candidate" 2>/dev/null || printf '%s' "$candidate")"
        [[ "$resolved" == "$root/bin/$name" ]] && continue
        duplicate=0
        for seen in "${foreign_paths[@]}"; do
            if [[ "$candidate" -ef "$seen" ]]; then
                duplicate=1
                break
            fi
        done
        ((duplicate)) && continue
        foreign_commands+=("$name:$candidate")
        foreign_paths+=("$candidate")
    done < <(
        for directory in /usr/local/bin /usr/bin /bin; do
            [[ -e "$directory/$name" || -L "$directory/$name" ]] &&
                printf '%s\n' "$directory/$name"
        done
    )
done

if command -v dpkg-query >/dev/null 2>&1; then
    for candidate in "${foreign_paths[@]}"; do
        owner="$(dpkg-query -S "$candidate" 2>/dev/null | head -n 1 || true)"
        package="${owner%%:*}"
        [[ -n "$package" && "$owner" == *:* ]] || continue
        status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)"
        [[ "$status" == "ii "* ]] || continue
        if [[ ! " ${installed_packages[*]} " =~ [[:space:]]${package}[[:space:]] ]]; then
            installed_packages+=("$package")
        fi
    done
fi

for candidate in "${user_candidates[@]}"; do
    [[ -e "$candidate" || -L "$candidate" ]] && present_user_roots+=("$candidate")
done

printf 'Foreign JavaScript runtime audit\n'
printf '  Sandwich: %s\n' "$root"
if ((${#foreign_commands[@]})); then
    printf '  command:  %s\n' "${foreign_commands[@]}"
else
    printf '  commands: none\n'
fi
if ((${#installed_packages[@]})); then
    printf '  Debian:   %s\n' "${installed_packages[*]}"
else
    printf '  Debian:   none\n'
fi
if ((${#present_user_roots[@]})); then
    printf '  user dir: %s\n' "${present_user_roots[@]}"
else
    printf '  user dirs: none\n'
fi

if [[ "$mode" == check ]]; then
    printf '  result:   preview only\n'
    exit 0
fi

[[ "$confirmation" == "PURGE-FOREIGN-JS" ]] || {
    printf 'sandwich: refusing purge without --confirm PURGE-FOREIGN-JS\n' >&2
    exit 2
}

if ((${#installed_packages[@]})); then
    command -v apt-get >/dev/null 2>&1 || {
        printf 'sandwich: installed Debian packages were found but apt-get is unavailable\n' >&2
        exit 1
    }
    if ((EUID == 0)); then
        apt-get purge -y -- "${installed_packages[@]}"
    else
        command -v sudo >/dev/null 2>&1 || {
            printf 'sandwich: sudo is required to purge Debian packages\n' >&2
            exit 1
        }
        sudo apt-get purge -y -- "${installed_packages[@]}"
    fi
fi

for candidate in "${present_user_roots[@]}"; do
    case "$candidate" in
        "$HOME/.nvm"|"$HOME/.npm-global"|"$HOME/.pnpm-store"|\
        "$HOME/.local/share/pnpm"|"$HOME/.yarn"|"$HOME/.node-gyp")
            rm -rf -- "$candidate"
            ;;
        *)
            printf 'sandwich: refusing unexpected purge target: %s\n' "$candidate" >&2
            exit 1
            ;;
    esac
done

printf '  result:   foreign runtimes removed; rerun sandwich doctor\n'
