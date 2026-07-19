#!/usr/bin/env bash
# Pin and audit the git author identity used by firstmate project worktrees.
#
# Usage:
#   fm-git-identity.sh pin <task-worktree> <project-dir> [projects-dir]
#   fm-git-identity.sh audit [projects-dir]
#
# `pin` enables Git's worktree-specific config and writes only user.name and
# user.email into the task worktree's config.worktree.
# It never changes a global identity or a project's shared local identity.
# `audit` is report-only: it prints the effective identity for each clone directly
# under projects-dir, flags mismatches, and exits 1 when it finds one.
#
# Every project receives QuinnBot <quinnbot@proton.me>, except project roots below
# ~/ventures/epstein and registered Epstein clones projects/research-core and
# projects/epstein-search, which receive Epstein Search <noreply@epsteinsearch.info>.
set -eu

FM_GIT_IDENTITY_FLEET_NAME='QuinnBot'
FM_GIT_IDENTITY_FLEET_EMAIL='quinnbot@proton.me'
FM_GIT_IDENTITY_EPSTEIN_NAME='Epstein Search'
FM_GIT_IDENTITY_EPSTEIN_EMAIL='noreply@epsteinsearch.info'

fm_git_identity_real_path_or_raw() {  # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

fm_git_identity_expected_for_project() {  # <project-dir> [projects-dir]
  local project=$1 projects=${2:-} project_real projects_real epstein_root epstein_real
  project_real=$(fm_git_identity_real_path_or_raw "$project")
  projects_real=
  if [ -n "$projects" ]; then
    projects_real=$(fm_git_identity_real_path_or_raw "$projects")
  fi

  if [ -n "${HOME:-}" ]; then
    epstein_root="$HOME/ventures/epstein"
    epstein_real=$(fm_git_identity_real_path_or_raw "$epstein_root")
    case "$project" in
      "$epstein_root"|"$epstein_root"/*)
        printf '%s\t%s\n' "$FM_GIT_IDENTITY_EPSTEIN_NAME" "$FM_GIT_IDENTITY_EPSTEIN_EMAIL"
        return 0
        ;;
    esac
    case "$project_real" in
      "$epstein_real"|"$epstein_real"/*)
        printf '%s\t%s\n' "$FM_GIT_IDENTITY_EPSTEIN_NAME" "$FM_GIT_IDENTITY_EPSTEIN_EMAIL"
        return 0
        ;;
    esac
  fi

  if [ -n "$projects" ]; then
    case "$project" in
      "$projects/research-core"|"$projects/epstein-search")
        printf '%s\t%s\n' "$FM_GIT_IDENTITY_EPSTEIN_NAME" "$FM_GIT_IDENTITY_EPSTEIN_EMAIL"
        return 0
        ;;
    esac
  fi

  case "$project_real" in
    "$projects_real/research-core"|"$projects_real/epstein-search")
      printf '%s\t%s\n' "$FM_GIT_IDENTITY_EPSTEIN_NAME" "$FM_GIT_IDENTITY_EPSTEIN_EMAIL"
      ;;
    *)
      printf '%s\t%s\n' "$FM_GIT_IDENTITY_FLEET_NAME" "$FM_GIT_IDENTITY_FLEET_EMAIL"
      ;;
  esac
}

fm_git_identity_worktree_config_is_enabled() {  # <repository>
  [ "$(git -C "$1" config --type=bool --get extensions.worktreeConfig 2>/dev/null || true)" = true ]
}

fm_git_identity_enable_worktree_config() {  # <repository>
  local repository=$1
  fm_git_identity_worktree_config_is_enabled "$repository" && return 0

  for _ in {1..20}; do
    if git -C "$repository" config extensions.worktreeConfig true >/dev/null 2>&1; then
      return 0
    fi
    fm_git_identity_worktree_config_is_enabled "$repository" && return 0
    sleep 0.05
  done

  echo "error: could not enable worktree-specific Git config for $repository after 20 attempts" >&2
  return 1
}

fm_git_identity_pin_worktree() {  # <task-worktree> <project-dir> [projects-dir]
  local worktree=$1 project=$2 projects=${3:-} expected name email
  expected=$(fm_git_identity_expected_for_project "$project" "$projects")
  IFS=$'\t' read -r name email <<EOF
$expected
EOF
  fm_git_identity_enable_worktree_config "$worktree"
  git -C "$worktree" config --worktree user.name "$name"
  git -C "$worktree" config --worktree user.email "$email"
}

fm_git_identity_audit() {  # [projects-dir]
  local projects=${1:-"${FM_PROJECTS_OVERRIDE:-${FM_HOME:-.}/projects}"}
  local clone clone_real top top_real expected expected_name expected_email actual_name actual_email
  local clones=0 mismatches=0
  [ -d "$projects" ] || {
    printf 'ok: no projects directory at %s\n' "$projects"
    return 0
  }

  shopt -s nullglob
  for clone in "$projects"/*; do
    [ -d "$clone" ] || continue
    top=$(git -C "$clone" rev-parse --show-toplevel 2>/dev/null || true)
    [ -n "$top" ] || continue
    clone_real=$(fm_git_identity_real_path_or_raw "$clone")
    top_real=$(fm_git_identity_real_path_or_raw "$top")
    [ "$clone_real" = "$top_real" ] || continue
    clones=$((clones + 1))

    expected=$(fm_git_identity_expected_for_project "$clone" "$projects")
    IFS=$'\t' read -r expected_name expected_email <<EOF
$expected
EOF
    actual_name=$(git -C "$clone" config --get user.name 2>/dev/null || true)
    actual_email=$(git -C "$clone" config --get user.email 2>/dev/null || true)
    if [ "$actual_name" = "$expected_name" ] && [ "$actual_email" = "$expected_email" ]; then
      printf 'ok: %s identity=%s <%s>\n' "$clone" "$actual_name" "$actual_email"
    else
      printf 'flag: %s identity=%s <%s> expected=%s <%s>\n' \
        "$clone" "${actual_name:-unset}" "${actual_email:-unset}" "$expected_name" "$expected_email"
      mismatches=$((mismatches + 1))
    fi
  done
  shopt -u nullglob

  if [ "$clones" -eq 0 ]; then
    printf 'ok: no git clones under %s\n' "$projects"
  fi
  [ "$mismatches" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    pin)
      [ "$#" -ge 3 ] && [ "$#" -le 4 ] || {
        echo "usage: $0 pin <task-worktree> <project-dir> [projects-dir]" >&2
        exit 2
      }
      fm_git_identity_pin_worktree "$2" "$3" "${4:-}"
      ;;
    audit)
      [ "$#" -le 2 ] || {
        echo "usage: $0 audit [projects-dir]" >&2
        exit 2
      }
      fm_git_identity_audit "${2:-}"
      ;;
    *)
      echo "usage: $0 {pin <task-worktree> <project-dir> [projects-dir]|audit [projects-dir]}" >&2
      exit 2
      ;;
  esac
fi
