# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_worktree_smoke.rb
#
# Smoke-tests git provenance resolution (#137) against a real Rails boot.
# Version-agnostic: prints the detected Rails version.
#
# In a linked worktree, .git is a file with a gitdir: pointer to the real git
# directory. When that directory can't be resolved (e.g. an unmounted host path
# in a container), Woods::GitProvenance must report "unknown" rather than a stale
# GIT_BRANCH/GIT_SHA build arg.

require 'tmpdir'
require 'woods/git_provenance'

results = []

def assert(name)
  yield
  puts "  PASS  #{name}"
  true
rescue StandardError => e
  puts "  FAIL  #{name}: #{e.class}: #{e.message}"
  false
end

puts '=== Rails environment ==='
puts "Rails:           #{Rails.version}"
puts "Ruby:            #{RUBY_VERSION}"
puts

puts '=== unresolvable worktree git dir: report "unknown", not a stale env value (#137) ==='

Dir.mktmpdir('woods_worktree') do |dir|
  # Simulate a worktree whose real git dir is not mounted: .git is a file
  # pointing at a path that does not exist in this container.
  File.write(File.join(dir, '.git'), "gitdir: /nonexistent/host/path/.git/worktrees/wt\n")
  stale = { 'GIT_BRANCH' => 'baked-stale-branch', 'GIT_SHA' => 'deadbeefstale' }
  provenance = Woods::GitProvenance.new(root: dir, env: stale)

  results << assert('branch resolves to "unknown" (not the stale env value)') do
    raise "got #{provenance.branch.inspect}" unless provenance.branch == 'unknown'
  end

  results << assert('sha resolves to "unknown" (not the stale env value)') do
    raise "got #{provenance.sha.inspect}" unless provenance.sha == 'unknown'
  end
end

puts
puts '=== provenance for the booted app root never crashes; prints resolved or "unknown" ==='

app_provenance = Woods::GitProvenance.new(root: Rails.root)
branch = app_provenance.branch
sha = app_provenance.sha
puts "  Rails.root branch: #{branch}"
puts "  Rails.root sha:    #{sha}"

results << assert('app provenance returns non-empty strings (resolved or "unknown")') do
  raise 'empty branch' if branch.to_s.empty?
  raise 'empty sha' if sha.to_s.empty?
end

puts
puts '=== Summary ==='
passed = results.count(true)
failed = results.count(false)
puts "passed: #{passed}    failed: #{failed}    total: #{results.size}"
exit(failed.zero? ? 0 : 1)
