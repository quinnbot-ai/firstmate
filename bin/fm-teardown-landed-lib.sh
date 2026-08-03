#!/usr/bin/env bash
# Shared landed-work proof used by bin/fm-teardown.sh and the explicit legacy
# metadata reconciler.  Callers set WT, PROJ, and PR_URL before invoking it.

fm_teardown_default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

fm_teardown_pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_teardown_pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '') return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*) n=${target%%[!0-9]*} ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_teardown_ensure_commit_object() {
  local target=$1 commit=$2 n
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(fm_teardown_pr_number_from_target "$target") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null
}

fm_teardown_patch_id_for_commit() {
  local commit=$1
  git -C "$WT" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

fm_teardown_unpushed_patches_are_in_pr_head() {
  local pr_head=$1 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$WT" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(git -C "$WT" log --format=%H "$base..$pr_head" -- 2>/dev/null \
    | while IFS= read -r commit; do
        fm_teardown_patch_id_for_commit "$commit"
      done \
    | sed '/^$/d' \
    | sort -u) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$WT" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(fm_teardown_patch_id_for_commit "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# <branch> [recorded-only]
fm_teardown_pr_is_merged() {
  local branch=$1 recorded_only=${2:-0} target view state head current
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  elif [ "$recorded_only" = 1 ]; then
    return 1
  else
    target=$(fm_teardown_pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  fm_teardown_ensure_commit_object "$target" "$head" || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null && return 0
  fm_teardown_unpushed_patches_are_in_pr_head "$head"
}

fm_teardown_content_in_default() {
  local name ref default_tree merged_tree
  name=$(fm_teardown_default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# The normal teardown proof remains owned by bin/fm-teardown.sh, which invokes
# this shared implementation after its dirty-worktree checks.
fm_teardown_work_is_landed() {
  local branch=$1
  fm_teardown_pr_is_merged "$branch" && return 0
  fm_teardown_content_in_default
}

# The explicit legacy reconciler accepts only the recorded PR proof, never
# branch discovery, and only a local default-branch ancestry proof.
fm_teardown_local_main_contains_task_branch() {
  local task_id=$1 default branch_head main_head
  default=$(fm_teardown_default_branch) || return 1
  branch_head=$(git -C "$PROJ" rev-parse --verify "refs/heads/fm/$task_id^{commit}" 2>/dev/null) || return 1
  main_head=$(git -C "$PROJ" rev-parse --verify "refs/heads/$default^{commit}" 2>/dev/null) || return 1
  git -C "$PROJ" merge-base --is-ancestor "$branch_head" "$main_head" 2>/dev/null
}

fm_teardown_json_string_field() {
  local field=$1
  awk -v wanted="$field" '
    {
      line = $0 "\n"
      for (i = 1; i <= length(line); i++) {
        char = substr(line, i, 1)
        if (in_string) {
          if (escaped) {
            token = token "\\" char
            escaped = 0
          } else if (char == "\\") {
            escaped = 1
          } else if (char == "\"") {
            in_string = 0
            if (mode == "key") {
              key = token
              key_ready = 1
            } else if (mode == "value") {
              matches++
              result = token
            }
            mode = ""
          } else {
            token = token char
          }
          continue
        }
        if (char == "\"") {
          in_string = 1
          token = ""
          if (depth == 1 && expect_key) {
            mode = "key"
            expect_key = 0
          } else if (depth == 1 && want_value) {
            mode = "value"
            want_value = 0
          } else {
            mode = "other"
          }
        } else if (char == "{" || char == "[") {
          depth++
          if (depth == 1) {
            expect_key = 1
          }
        } else if (char == "}" || char == "]") {
          depth--
          if (depth < 0) {
            invalid = 1
          }
        } else if (depth == 1 && char == ":") {
          if (key_ready) {
            want_value = (key == wanted)
            key_ready = 0
          }
        } else if (depth == 1 && char == ",") {
          expect_key = 1
          want_value = 0
          key_ready = 0
        }
      }
    }
    END {
      if (!invalid && !in_string && depth == 0 && matches == 1) {
        print result
      } else {
        exit 1
      }
    }
  '
}

fm_teardown_recorded_pr_head() {
  local target=$1 view state merged head project_id
  FM_TEARDOWN_RECORDED_PR_HEAD=
  fm_pr_url_parse "$target" || return 1
  case "$FM_PR_PROVIDER" in
    github)
      view=$(cd "$PROJ" && gh api "repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER" \
        --jq '[.state, .merged, .head.sha] | @tsv' 2>/dev/null) || return 1
      state=${view%%$'\t'*}
      view=${view#*$'\t'}
      merged=${view%%$'\t'*}
      head=${view#*$'\t'}
      [ "$state" = closed ] && [ "$merged" = true ] || return 1
      ;;
    gitlab)
      project_id=${FM_PR_PATH//\//%2F}
      view=$(cd "$PROJ" && glab api --hostname "$FM_PR_HOST" \
        "projects/$project_id/merge_requests/$FM_PR_NUMBER" 2>/dev/null) || return 1
      state=$(printf '%s\n' "$view" | fm_teardown_json_string_field state) || return 1
      head=$(printf '%s\n' "$view" | fm_teardown_json_string_field sha) || return 1
      [ "$state" = merged ] || return 1
      ;;
    *) return 1 ;;
  esac
  fm_pr_head_valid "$head" || return 1
  FM_TEARDOWN_RECORDED_PR_HEAD=$head
}

fm_teardown_forge_head_contains_commit() {
  local branch_head=$1 head=$2 status project_id merge_base
  [ "$branch_head" = "$head" ] && return 0
  case "$FM_PR_PROVIDER" in
    github)
      status=$(cd "$PROJ" && gh api "repos/$FM_PR_PATH/compare/$branch_head...$head" \
        --jq .status 2>/dev/null) || return 1
      [ "$status" = ahead ]
      ;;
    gitlab)
      project_id=${FM_PR_PATH//\//%2F}
      status=$(cd "$PROJ" && glab api --hostname "$FM_PR_HOST" \
        "projects/$project_id/repository/merge_base?refs%5B%5D=$branch_head&refs%5B%5D=$head" \
        2>/dev/null) || return 1
      merge_base=$(printf '%s\n' "$status" | fm_teardown_json_string_field id) || return 1
      [ "$merge_base" = "$branch_head" ]
      ;;
    *) return 1 ;;
  esac
}

# The detached legacy records no longer have their original worktree, so this
# proof compares their durable task branch directly with the recorded PR head.
fm_teardown_recorded_pr_contains_task_branch() {
  local task_id=$1 head branch_head
  [ -n "$PR_URL" ] || return 1
  fm_teardown_recorded_pr_head "$PR_URL" || return 1
  head=$FM_TEARDOWN_RECORDED_PR_HEAD
  branch_head=$(git -C "$PROJ" rev-parse --verify "refs/heads/fm/$task_id^{commit}" 2>/dev/null) || return 1
  fm_teardown_forge_head_contains_commit "$branch_head" "$head"
}
