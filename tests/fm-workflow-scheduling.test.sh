#!/usr/bin/env bash
# Contract tests for GitHub Actions scheduling and lifecycle selection.
#
# The workflows are executable configuration, so this test parses their public
# YAML contract rather than matching source text. It protects the cost boundary:
# complete Ubuntu coverage remains on every PR, the only current macOS job uses
# native path filtering plus a daily run, and no-mistakes ignores only the PR
# creation event that can precede its signature.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"
MACOS_WORKFLOW="$ROOT/.github/workflows/macos-stock-bash.yml"
NO_MISTAKES_WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"

assert_workflow_contract() {
  ruby - "$CI_WORKFLOW" "$MACOS_WORKFLOW" "$NO_MISTAKES_WORKFLOW" <<'RUBY'
require "yaml"

ci_path, macos_path, no_mistakes_path = ARGV
ci = YAML.load_file(ci_path)
macos = YAML.load_file(macos_path)
no_mistakes = YAML.load_file(no_mistakes_path)
trigger = true

def require_equal(actual, expected, label)
  return if actual == expected

  raise "#{label}: expected #{expected.inspect}, got #{actual.inspect}"
end

def require_present(value, label)
  return unless value.nil? || value == false || value == ""

  raise "#{label}: missing"
end

ci_events = ci.fetch(trigger)
require_equal(ci_events.keys, ["pull_request"], "CI events")
require_equal(ci_events.fetch("pull_request").fetch("branches"), ["main"], "CI PR target")

ubuntu_jobs = %w[
  lint
  test-coverage
  tests-portable-parallel-1
  tests-portable-parallel-2
  tests-portable-serial
  tests-herdr
  tests-timing-aggregate
  invariants
]
require_equal(ci.fetch("jobs").keys.sort, ubuntu_jobs.sort, "CI job inventory")
ci.fetch("jobs").each do |name, job|
  require_equal(job.fetch("runs-on"), "ubuntu-latest", "CI job #{name} runner")
end

macos_events = macos.fetch(trigger)
require_equal(macos_events.keys.sort, %w[pull_request schedule], "macOS workflow events")
macos_pr = macos_events.fetch("pull_request")
require_equal(macos_pr.fetch("branches"), ["main"], "macOS PR target")
paths = macos_pr.fetch("paths")
macos_paths = %w[
  .github/workflows/macos-stock-bash.yml
  bin/**
  tests/lib.sh
  tests/fm-fleet-snapshot-view.test.sh
  tests/fm-bearings-snapshot.test.sh
  tests/fm-test-run.test.sh
]
require_equal(paths, macos_paths, "macOS PR paths")
require_equal(macos_events.fetch("schedule"), [{"cron" => "17 5 * * *"}], "macOS daily schedule")
macos_jobs = macos.fetch("jobs")
require_equal(macos_jobs.keys, ["macos-stock-bash"], "macOS job inventory")
macos_job = macos_jobs.fetch("macos-stock-bash")
require_equal(macos_job.fetch("runs-on"), "macos-latest", "macOS runner")
require_equal(macos_job.fetch("steps")[1].fetch("shell"), "/bin/bash {0}", "macOS stock Bash shell")

types = no_mistakes.fetch(trigger).fetch("pull_request").fetch("types")
require_equal(types, %w[edited synchronize reopened], "no-mistakes lifecycle events")
check = no_mistakes.fetch("jobs").fetch("check")
require_present(check.fetch("if").include?("github-actions[bot]"), "no-mistakes bot exemption")
require_present(check.fetch("if").include?("dependabot[bot]"), "no-mistakes Dependabot exemption")
require_present(
  check.fetch("steps").any? { |step| step.dig("env", "PR_BODY") == "${{ github.event.pull_request.body }}" },
  "no-mistakes signature body input"
)
concurrency = no_mistakes.fetch("concurrency").fetch("group")
require_present(concurrency.include?("github.event.action == 'edited'"), "no-mistakes body-edit isolation")
raise "no-mistakes concurrency must not restore opened-event handling" if concurrency.include?("opened")
RUBY
}

test_workflow_event_and_runner_contract() {
  assert_workflow_contract || fail "workflow scheduling contract failed"
  pass "workflow scheduling retains Ubuntu PR coverage, gates macOS natively, and skips impossible no-mistakes opens"
}

test_workflow_event_and_runner_contract
