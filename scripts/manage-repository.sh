#!/usr/bin/env bash

set -Eeuo pipefail

sandwich_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
action="${1:-audit}"
[[ "$action" == "audit" || "$action" == "update" ]] || {
    printf 'Usage: sandwich repository [audit|update] [options]\n' >&2
    exit 2
}
shift || true

repository_root="$PWD"
source_remote=""
source_url=""
source_branch=""
fork_remote=""
fork_url=""
fork_branch=""
publish_mode="ff"
doctor_script=""
verify_script=""
commit_message="chore: refresh owner-managed dependencies"
dry_run=0
owner_args=()

usage() {
    cat <<'EOF'
Usage: sandwich repository audit [options]
       sandwich repository update [options]

Options:
  --root=PATH                 repository checkout (default: current directory)
  --source-remote=NAME        remote that owns upstream development
  --source-url=URL            expected URL for the source remote
  --source-branch=BRANCH      branch to inspect or merge from the source remote
  --fork-remote=NAME          remote that receives reviewed local work
  --fork-url=URL              expected URL for the publishing remote
  --fork-branch=BRANCH        publishing branch on the fork
  --publish-mode=MODE         ff or force-with-lease (default: ff)
  --doctor=PATH               repository-relative read-only doctor
  --verify=PATH               repository-relative update/integration verifier
  --commit-message=TEXT       commit message for verified tracked maintenance edits
  --dry-run                   report an update without changing the checkout

Audit fetches named remotes, reports source/fork divergence, performs a scoped
Sandwich dependency dry-run when a Bun lockfile exists, and runs the owner
doctor. Update reconciles the publishing branch and source branch when safe,
runs the scoped dependency update and owner verifier, commits only verified
tracked maintenance edits, and prints an exact push command. It never pushes.
EOF
}

while (($#)); do
    case "$1" in
        --root=*) repository_root="${1#*=}" ;;
        --source-remote=*) source_remote="${1#*=}" ;;
        --source-url=*) source_url="${1#*=}" ;;
        --source-branch=*) source_branch="${1#*=}" ;;
        --fork-remote=*) fork_remote="${1#*=}" ;;
        --fork-url=*) fork_url="${1#*=}" ;;
        --fork-branch=*) fork_branch="${1#*=}" ;;
        --publish-mode=*) publish_mode="${1#*=}" ;;
        --doctor=*) doctor_script="${1#*=}" ;;
        --verify=*) verify_script="${1#*=}" ;;
        --commit-message=*) commit_message="${1#*=}" ;;
        --dry-run) dry_run=1 ;;
        --) shift; owner_args=("$@"); break ;;
        --help|-h|help) usage; exit 0 ;;
        *) printf 'Unknown repository option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ -n "$source_remote" && -n "$source_url" && -n "$source_branch" ]] || {
    printf 'Source remote, URL, and branch are required.\n' >&2
    exit 2
}
[[ "$publish_mode" == "ff" || "$publish_mode" == "force-with-lease" ]] || {
    printf 'Publish mode must be ff or force-with-lease.\n' >&2
    exit 2
}
for remote_name in "$source_remote" "$fork_remote"; do
    [[ -z "$remote_name" || "$remote_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
        printf 'Invalid Git remote name: %s\n' "$remote_name" >&2
        exit 2
    }
done
for branch_name in "$source_branch" "$fork_branch"; do
    [[ -z "$branch_name" ]] || git check-ref-format --branch "$branch_name" >/dev/null
done

repository_root="$(realpath -e -- "$repository_root")"
git -C "$repository_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf 'Not a Git checkout: %s\n' "$repository_root" >&2
    exit 1
}
current_branch="$(git -C "$repository_root" branch --show-current)"
[[ -n "$current_branch" ]] || {
    printf 'A checked-out publishing branch is required: %s\n' "$repository_root" >&2
    exit 1
}

resolve_owner_script() {
    local relative="$1"
    [[ -n "$relative" ]] || return 0
    local resolved
    resolved="$(realpath -m -- "$repository_root/$relative")"
    [[ "$resolved" == "$repository_root/"* && -f "$resolved" ]] || {
        printf 'Owner script is missing or outside the repository: %s\n' "$relative" >&2
        return 1
    }
    printf '%s\n' "$resolved"
}

doctor_path="$(resolve_owner_script "$doctor_script")"
verify_path="$(resolve_owner_script "$verify_script")"

failures=0

ensure_remote() {
    local name="$1"
    local expected="$2"
    [[ -n "$name" ]] || return 0
    local current
    current="$(git -C "$repository_root" remote get-url "$name" 2>/dev/null || true)"
    if [[ "$current" == "$expected" ]]; then
        return 0
    fi
    if [[ "$action" == "audit" || "$dry_run" == 1 ]]; then
        printf 'Remote %s: expected %s, found %s\n' \
            "$name" "$expected" "${current:-<missing>}" >&2
        failures=$((failures + 1))
        return 1
    fi
    if [[ -n "$current" ]]; then
        git -C "$repository_root" remote set-url "$name" "$expected"
        printf 'Repaired remote %s -> %s\n' "$name" "$expected"
    else
        git -C "$repository_root" remote add "$name" "$expected"
        printf 'Added remote %s -> %s\n' "$name" "$expected"
    fi
}

ensure_remote "$source_remote" "$source_url" || true
if [[ -n "$fork_remote" ]]; then
    [[ -n "$fork_url" && -n "$fork_branch" ]] || {
        printf 'Fork URL and branch are required when a fork remote is declared.\n' >&2
        exit 2
    }
    ensure_remote "$fork_remote" "$fork_url" || true
fi
if ((failures)); then
    exit 1
fi

git -C "$repository_root" fetch --prune "$source_remote"
if [[ -n "$fork_remote" && "$fork_remote" != "$source_remote" ]]; then
    git -C "$repository_root" fetch --prune "$fork_remote"
fi

source_ref="refs/remotes/$source_remote/$source_branch"
git -C "$repository_root" show-ref --verify --quiet "$source_ref" || {
    printf 'Source branch is unavailable: %s/%s\n' "$source_remote" "$source_branch" >&2
    exit 1
}
fork_ref=""
if [[ -n "$fork_remote" ]]; then
    fork_ref="refs/remotes/$fork_remote/$fork_branch"
fi

relation_to_head() {
    local ref="$1"
    if git -C "$repository_root" merge-base --is-ancestor "$ref" HEAD; then
        printf 'contained\n'
    elif git -C "$repository_root" merge-base --is-ancestor HEAD "$ref"; then
        printf 'fast-forward\n'
    elif git -C "$repository_root" merge-tree --write-tree HEAD "$ref" >/dev/null 2>&1; then
        printf 'clean-merge\n'
    else
        printf 'conflict\n'
    fi
}

report_ref() {
    local label="$1"
    local ref="$2"
    if ! git -C "$repository_root" show-ref --verify --quiet "$ref"; then
        printf '  %-10s missing\n' "$label"
        return
    fi
    local behind ahead
    read -r behind ahead < <(git -C "$repository_root" rev-list --left-right --count "$ref...HEAD")
    printf '  %-10s behind=%s ahead=%s relation=%s\n' \
        "$label" "$behind" "$ahead" "$(relation_to_head "$ref")"
}

printf 'Repository owner state\n'
printf '  root:       %s\n' "$repository_root"
printf '  branch:     %s\n' "$current_branch"
report_ref source "$source_ref"
if [[ -n "$fork_ref" ]]; then
    report_ref fork "$fork_ref"
fi

worktree_state="$(git -C "$repository_root" status --porcelain --untracked-files=all)"
if [[ -n "$worktree_state" ]]; then
    printf '  worktree:   dirty\n%s\n' "$worktree_state" >&2
    failures=$((failures + 1))
else
    printf '  worktree:   clean\n'
fi

merge_ref() {
    local label="$1"
    local ref="$2"
    local relation
    relation="$(relation_to_head "$ref")"
    case "$relation" in
        contained)
            printf '%s is already contained.\n' "$label"
            ;;
        fast-forward)
            git -C "$repository_root" merge --ff-only "$ref"
            ;;
        clean-merge)
            git -C "$repository_root" merge --no-ff --no-edit "$ref"
            ;;
        *)
            printf '%s does not merge cleanly; review is required.\n' "$label" >&2
            return 1
            ;;
    esac
}

configure_publish_target() {
    [[ -n "$fork_ref" ]] || return 0
    if git -C "$repository_root" show-ref --verify --quiet "$fork_ref"; then
        git -C "$repository_root" branch --set-upstream-to="$fork_remote/$fork_branch" "$current_branch" >/dev/null
    fi
    git -C "$repository_root" config remote.pushDefault "$fork_remote"
    git -C "$repository_root" config "branch.$current_branch.pushRemote" "$fork_remote"
    if [[ "$current_branch" == "$fork_branch" ]]; then
        git -C "$repository_root" config push.default simple
    else
        git -C "$repository_root" config push.default upstream
    fi
}

run_dependency_check() {
    local mode="$1"
    if [[ -f "$repository_root/bun.lock" || -f "$repository_root/bun.lockb" ]]; then
        if [[ "$mode" == "audit" ]]; then
            "$sandwich_root/bin/sandwich" checkExpr --dryrun "$repository_root"
        else
            "$sandwich_root/bin/sandwich" checkExpr "$repository_root"
        fi
    else
        printf 'Dependency audit: no Bun lockfile; owner verifier retains package-manager policy.\n'
    fi
}

push_hint() {
    [[ -n "$fork_remote" ]] || return 0
    local owner_prefix="Publish with"
    if [[ "$fork_url" == *github.com/CommanderTurtle/* ]]; then
        owner_prefix="If you are CommanderTurtle, publish with"
    fi
    if ! git -C "$repository_root" show-ref --verify --quiet "$fork_ref"; then
        printf '%s:\n  git push --set-upstream %q HEAD:%q\n' \
            "$owner_prefix" "$fork_remote" "$fork_branch"
        return
    fi
    local fork_head
    fork_head="$(git -C "$repository_root" rev-parse "$fork_ref")"
    if [[ "$(git -C "$repository_root" rev-parse HEAD)" == "$fork_head" ]]; then
        printf 'Fork publishing branch is current; no push is needed.\n'
    elif [[ "$publish_mode" == "force-with-lease" ]]; then
        printf '%s:\n  git push --force-with-lease=%s/%s:%s %q HEAD:%q\n' \
            "$owner_prefix" "$fork_remote" "$fork_branch" "$fork_head" \
            "$fork_remote" "$fork_branch"
    elif git -C "$repository_root" merge-base --is-ancestor "$fork_ref" HEAD; then
        printf '%s:\n  git push %q HEAD:%q\n' \
            "$owner_prefix" "$fork_remote" "$fork_branch"
    else
        printf 'Fork publishing branch diverges and is not eligible for a normal push.\n' >&2
        failures=$((failures + 1))
    fi
}

if [[ "$action" == "audit" ]]; then
    run_dependency_check audit || failures=$((failures + 1))
    if [[ -n "$doctor_path" ]]; then
        bash "$doctor_path" "${owner_args[@]}" || failures=$((failures + 1))
    fi
    push_hint
    ((failures == 0))
    exit
fi

if ((dry_run)); then
    printf 'Dry run: would reconcile the fork/source refs, update scoped Bun dependencies, run %s, and prepare a local commit.\n' \
        "${verify_script:-the owner verifier}"
    push_hint
    exit 0
fi
if ((failures)); then
    printf 'Refusing to update a dirty repository.\n' >&2
    exit 1
fi

configure_publish_target
if [[ -n "$fork_ref" && "$publish_mode" == "ff" ]] && \
   git -C "$repository_root" show-ref --verify --quiet "$fork_ref"; then
    merge_ref "Fork branch $fork_remote/$fork_branch" "$fork_ref"
fi
merge_ref "Source branch $source_remote/$source_branch" "$source_ref"
run_dependency_check update
if [[ -n "$verify_path" ]]; then
    bash "$verify_path" "${owner_args[@]}"
fi

post_untracked="$(git -C "$repository_root" ls-files --others --exclude-standard)"
if [[ -n "$post_untracked" ]]; then
    printf 'Verifier created untracked files; add an ignore or review them before committing:\n%s\n' \
        "$post_untracked" >&2
    exit 1
fi
git -C "$repository_root" diff --check
if ! git -C "$repository_root" diff --quiet; then
    git -C "$repository_root" add -u
    git -C "$repository_root" commit -m "$commit_message"
fi

printf 'Repository update verified locally. No remote was pushed.\n'
push_hint
