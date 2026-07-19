#!/usr/bin/env bash

fm_treehouse_lease_handoff_read() {
  local handoff=$1 record=
  IFS= read -r record < "$handoff" || true
  case "$record" in
    leased=/*)
      printf 'leased\t%s\n' "${record#leased=}"
      ;;
    returning=/*)
      printf 'returning\t%s\n' "${record#returning=}"
      ;;
    returned=/*)
      printf 'returned\t%s\n' "${record#returned=}"
      ;;
    /*)
      printf 'leased\t%s\n' "$record"
      ;;
    *) return 1 ;;
  esac
}

fm_treehouse_lease_handoff_write() {
  local handoff=$1 handoff_state=$2 lease_path=$3
  printf '%s=%s\n' "$handoff_state" "$lease_path" > "$handoff"
}
