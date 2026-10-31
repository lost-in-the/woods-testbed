# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_flow_lib_step_smoke.rb
#
# woods#945 testbed smoke: an incremental run keeps a controller's flow
# document equal to a full extraction's when the flow steps into a lib class
# the dependency graph holds no edge to.
#
# The scenario, written as transient fixtures so it runs unchanged on every
# variant:
#
#   lib/woods_smoke_flow/woods_smoke_step_tracker.rb
#     WoodsSmokeFlow::WoodsSmokeStepTracker#track
#   app/controllers/woods_smoke_flow_steps_controller.rb
#     #show calls `WoodsSmokeStepTracker.new.track(...)` by its short name
#
# Woods' flow assembler resolves the short name by suffix and steps into the
# lib class; the reference scanner records no controller -> lib edge for it.
# Before woods#949 the incremental flow refresh walked only graph edges, so a
# lib edit left the controller's flow carried forward with the old step lines.
#
#   1. Full: `woods:extract` into index A. The controller's flow steps into
#      the tracker. Whether the graph holds the edge is reported, not
#      asserted: a later gem that records it keeps this smoke meaningful as
#      an equivalence check.
#   2. Incremental: one comment line goes in above `track`, and
#      `CHANGED_FILES=<the lib file> woods:incremental` updates index A.
#   3. Oracle: `woods:extract` into index B from the edited tree. A's flow
#      artifacts equal B's (generated_at and Proc addresses normalized), and
#      the tracker step's lines moved from the baseline.
#
# Every extraction is a fresh `bin/rails` boot, the way the tasks are really
# invoked: the fixtures are written after this runner booted, so its own
# constants never saw them. Flow precomputation comes from a TRANSIENT
# initializer (the knob has no env override). Fixtures, the initializer and
# both indexes are removed on the way out; a pre-existing file with one of
# the fixture names is never overwritten or deleted.
#
# Exit codes: 0 pass, 1 failure.

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'woods/generation'
require_relative 'support/flow_document_inventory'

ENTRY_POINT = 'WoodsSmokeFlowStepsController#show'
CONTROLLER = 'WoodsSmokeFlowStepsController'
TRACKER = 'WoodsSmokeFlow::WoodsSmokeStepTracker'
LIB_FILE = 'lib/woods_smoke_flow/woods_smoke_step_tracker.rb'

def tracker_source(padding = '')
  <<~RUBY
    # frozen_string_literal: true

    # Transient: written by script/shared/woods_flow_lib_step_smoke.rb.
    module WoodsSmokeFlow
      class WoodsSmokeStepTracker
    #{padding}    def track(id)
          Rails.logger.info("woods smoke flow step \#{id}")
        end
      end
    end
  RUBY
end

FIXTURES = {
  LIB_FILE => tracker_source,
  'app/controllers/woods_smoke_flow_steps_controller.rb' => <<~RUBY,
    # frozen_string_literal: true

    # Transient: written by script/shared/woods_flow_lib_step_smoke.rb.
    class WoodsSmokeFlowStepsController < ApplicationController
      def show
        WoodsSmokeStepTracker.new.track(params[:id]) if params[:id]
        head :ok
      end
    end
  RUBY
  'config/initializers/zzz_woods_flow_lib_step_smoke.rb' => <<~RUBY
    # frozen_string_literal: true

    # Transient: written by script/shared/woods_flow_lib_step_smoke.rb so its
    # extractions boot with flow precomputation enabled. Deleted by the smoke.
    Woods.configure { |c| c.precompute_flows = true }
  RUBY
}.freeze

EDITED_LIB = tracker_source("    # woods#945: one line above the step\n")

results = []

def assert(name)
  yield
  puts "  PASS  #{name}"
  true
rescue StandardError => e
  puts "  FAIL  #{name}: #{e.class}: #{e.message}"
  false
end

def app_path(relative)
  Rails.root.join(relative)
end

# Byte-identical content is provably this smoke's own (a leftover from an
# interrupted run); anything else under a fixture name is the host's.
def ours?(relative)
  path = app_path(relative)
  path.file? && [FIXTURES[relative], (EDITED_LIB if relative == LIB_FILE)].compact.include?(path.read)
end

def write_fixtures
  FIXTURES.each_key do |relative|
    path = app_path(relative)
    raise "refusing to run: #{relative} exists and is not this smoke's fixture (left untouched)" if path.exist? && !ours?(relative)
  end
  FIXTURES.each do |relative, content|
    FileUtils.mkdir_p(app_path(relative).dirname)
    File.write(app_path(relative), content)
  end
end

def remove_fixtures
  FIXTURES.each_key { |relative| File.delete(app_path(relative)) if ours?(relative) }
  dir = app_path(File.dirname(LIB_FILE))
  Dir.rmdir(dir) if dir.directory? && Dir.empty?(dir)
end

# A file written on the host side of the bind mount can be served stale by
# bootsnap in the next boot; clear it and pause before every fresh boot.
def settle
  FileUtils.rm_rf(Rails.root.join('tmp/cache/bootsnap'))
  sleep 1
end

def rails_task(task, output_dir, env = {})
  settle
  out, err, status = Open3.capture3(
    { 'WOODS_OUTPUT' => output_dir, 'WOODS_IGNORE_WATCH' => '1' }.merge(env),
    Rails.root.join('bin/rails').to_s, task, chdir: Rails.root.to_s
  )
  raise "#{task} exited #{status.exitstatus}:\n#{out.lines.last(15).join}#{err.lines.last(15).join}" unless status.success?

  out
end

def payload_dir(output_dir)
  Woods::Generation.new(output_dir: output_dir).payload_dir
end

PROC_OBJECT_ID = /#<Proc:0x[0-9a-f]+/.freeze

def normalize(value)
  case value
  when String then value.gsub(PROC_OBJECT_ID, '#<Proc:0xSTRIPPED')
  when Hash then value.transform_values { |v| normalize(v) }
  when Array then value.map { |v| normalize(v) }
  else value
  end
end

def flow_index(output_dir)
  JSON.parse(payload_dir(output_dir).join('flows', 'flow_index.json').read)
end

def flow_artifacts(output_dir)
  FlowDocumentInventory.artifact_map(payload_dir(output_dir).join('flows')) { |content| normalize(content) }
end

def entry_document(output_dir)
  relative = flow_index(output_dir).fetch(ENTRY_POINT) { raise "#{ENTRY_POINT} missing from flow_index.json" }
  JSON.parse(payload_dir(output_dir).join(relative).read)
end

def tracker_steps(document)
  Array(document['steps']).select { |step| step['unit'].to_s.start_with?(TRACKER) }
end

def operation_lines(steps)
  steps.flat_map { |step| Array(step['operations']) }.filter_map { |operation| operation['line'] }
end

def graph_edge?(output_dir)
  graph = JSON.parse(payload_dir(output_dir).join('dependency_graph.json').read)
  Array(graph.dig('edges', CONTROLLER)).any? { |edge| edge['target'] == TRACKER }
end

woods_spec = Gem.loaded_specs['woods']
puts '=== Rails environment ==='
puts "Rails:            #{Rails.version}"
puts "Ruby:             #{RUBY_VERSION}"
puts "Woods:            #{woods_spec&.version} (#{woods_spec&.full_gem_path})"
puts

incremental_dir = Dir.mktmpdir('woods_flow_lib_step_incr', Rails.root.join('tmp').to_s)
full_dir = Dir.mktmpdir('woods_flow_lib_step_full', Rails.root.join('tmp').to_s)
baseline_lines = nil

begin
  write_fixtures

  puts '=== Section 1: full extraction steps into the lib class ==='
  results << assert('woods:extract with precompute_flows publishes the fixture flow') do
    rails_task('woods:extract', incremental_dir)
    entry_document(incremental_dir)
  end
  results << assert("#{ENTRY_POINT}'s flow steps into #{TRACKER}") do
    steps = tracker_steps(entry_document(incremental_dir))
    raise "no step names #{TRACKER}: #{entry_document(incremental_dir)['steps'].map { |s| s['unit'] }.inspect}" if steps.empty?

    baseline_lines = operation_lines(steps)
  end
  edge = graph_edge?(incremental_dir)
  puts "  INFO  graph edge #{CONTROLLER} -> #{TRACKER}: #{edge ? 'present (the scanner now records it)' : 'absent (the woods#945 shape)'}"

  puts
  puts "=== Section 2: incremental after an edit to #{LIB_FILE} ==="
  File.write(app_path(LIB_FILE), EDITED_LIB)
  results << assert('CHANGED_FILES woods:incremental completes') do
    rails_task('woods:incremental', incremental_dir, 'CHANGED_FILES' => LIB_FILE)
  end

  puts
  puts '=== Section 3: the incremental flows equal a full extraction of the edited tree ==='
  results << assert('woods:extract of the edited tree completes') { rails_task('woods:extract', full_dir) }
  results << assert("#{ENTRY_POINT}'s document equals the full run's") do
    incremental = normalize(entry_document(incremental_dir).except('generated_at'))
    full = normalize(entry_document(full_dir).except('generated_at'))
    raise "incremental tracker lines #{operation_lines(tracker_steps(incremental))}, full #{operation_lines(tracker_steps(full))}" unless incremental == full
  end
  results << assert('the tracker step moved with the edit') do
    moved = operation_lines(tracker_steps(entry_document(full_dir)))
    raise "lines did not move: baseline #{baseline_lines.inspect}, edited #{moved.inspect}" if moved == baseline_lines
  end
  results << assert('every flow artifact equals the full run') do
    incremental = flow_artifacts(incremental_dir)
    full = flow_artifacts(full_dir)
    differing = (incremental.keys | full.keys).reject { |key| incremental[key] == full[key] }
    raise "#{differing.size} differ: #{differing.first(10).join(', ')}" unless differing.empty?
  end
  results << assert('flow_index.json equals the full run') do
    raise 'flow_index.json differs' unless flow_index(incremental_dir) == flow_index(full_dir)
  end
rescue StandardError => e
  puts "  FAIL  smoke plumbing: #{e.class}: #{e.message}"
  results << false
ensure
  remove_fixtures
  FileUtils.rm_rf(incremental_dir)
  FileUtils.rm_rf(full_dir)
end

passed = results.count(true)
failed = results.count(false)
puts
puts '=== Summary ==='
puts "passed: #{passed}    failed: #{failed}    total: #{results.size}"
exit(failed.zero? ? 0 : 1)
