# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/woods_flows_smoke.rb
#
# PR-4 testbed smoke: `precompute_flows` end-to-end against a real Rails boot
# (docs/self-analysis/v2-prerelease-audit/12-remediation-plan.md, PR-4 row).
#
#   1. Full: a full extraction with the knob enabled publishes the flows/
#      family — flow_index.json exists and parses, every referenced flow
#      document exists and parses — and `woods:validate` passes with the
#      family present. That is the G-2 regression proof: the validator
#      used to fail any index published with flows on, complaining
#      "Missing _index.json in flows/".
#   2. Incremental: touch ONE controller (append an action, then remove it
#      again by restoring the original bytes), driving each change through
#      a fresh-boot incremental. After each leg:
#        - `woods:validate` still passes;
#        - flow_index.json reflects the change — the touched controller's
#          entries are replaced wholesale, so the added action enters the
#          index and, once removed, leaves it (the M3 delta contract);
#        - the removed action's flow document is swept — every flows/
#          document is referenced by the index, no orphans;
#        - the controllers _index.json entry for the touched controller is
#          re-derived (estimated_tokens move with the annotation).
#   3. Equivalence: with the tree back at its original state, a full
#      extraction reproduces the incremental run's flow inventory exactly
#      — same entry points, same document set (the M3 oracle).
#
# Two modes, one file:
#
#   smoke (default) runs the sections above.
#
#   Each incremental leg spawns `bin/rails woods:incremental` with
#     CHANGED_FILES=<the touched controller> — the documented CI contract —
#     so the delta runs in a fresh boot exactly the way a real invocation
#     would: the edited file is autoloaded from disk, and the gem
#     re-extracts the controller through a constant that reflects it.
#     (Driving extract_changed from this long-lived runner instead proved
#     unfaithful: the gem re-extracts class-based units through the loaded
#     constant, and within a `rails runner` process that constant did not
#     reflect the edited file even though the boot postdated the edit and
#     the file-based source read did — the recorded unit had the probe
#     action in source_code but not in metadata.actions. The production
#     invocation path does not have this problem and is what the smoke
#     therefore exercises.)
#
# The knob is enabled in-process via Woods.configure for the full runs.
# The leg subprocesses read it from a TRANSIENT initializer this script
# writes before the first leg and deletes afterwards (the knob has no env
# override, and the incremental flow refresh is gated on it); no variant
# initializer is permanently touched.
#
# Variants without app controllers skip cleanly. Exit codes: 0 pass/skip,
# 1 failure.

require 'json'
require 'open3'
require 'rake'
require 'stringio'
require 'woods/extractor'
require 'woods/filename_utils'
require 'woods/generation'

PROBE_ACTION = 'smoke_probe_action'

results = []

def assert(name, &block)
  block.call
  puts "  PASS  #{name}"
  true
rescue StandardError => e
  puts "  FAIL  #{name}: #{e.class}: #{e.message}"
  false
end

woods_spec = Gem.loaded_specs['woods']

puts '=== Rails environment ==='
puts "Rails:            #{Rails.version}"
puts "Ruby:             #{RUBY_VERSION}"
puts "Woods:            #{woods_spec&.version} (#{woods_spec&.full_gem_path})"
puts "precompute_flows: on (set by this script via Woods.configure)"
puts

# Skip rule, woods_smoke-style: the smoke maps controller actions, so a
# variant without any app controller has nothing to smoke.
controller_files = Dir[Rails.root.join('app/controllers/**/*_controller.rb').to_s]
                   .reject { |path| path.end_with?('/application_controller.rb') }

if controller_files.empty?
  puts '=== Skipped: no app controllers in this variant — nothing for precompute_flows to map ==='
  puts
  puts '=== Summary ==='
  puts 'passed: 0    failed: 0    total: 0'
  exit 0
end

output_dir = ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods').to_s)
ENV['WOODS_OUTPUT'] = output_dir # one resolution for extraction, legs, and validate
Woods.configure { |c| c.precompute_flows = true }

# Extraction logs at info; silence it so the smoke output stays readable.
# Process-local: this runner exits when the script does.
Rails.logger.level = Logger::ERROR if Rails.logger.respond_to?(:level=)

# ── Index-reading helpers ────────────────────────────────────────────────
# Same read path as woods_smoke.rb / woods_contract_smoke.rb: the gem
# publishes under payloads/gen-N/ and names the current one in
# generation.json; resolve through Woods::Generation rather than globbing.

def payload_dir(output_dir)
  Woods::Generation.new(output_dir: output_dir).payload_dir
rescue NameError
  Pathname.new(output_dir)
end

def flows_dir(output_dir)
  payload_dir(output_dir).join('flows')
end

def flow_index(output_dir)
  path = flows_dir(output_dir).join('flow_index.json')
  raise "flow_index.json missing at #{path}" unless path.file?

  JSON.parse(path.read)
end

# Document basenames currently on disk in flows/, index excluded.
def flow_documents(output_dir)
  Dir[flows_dir(output_dir).join('*.json')].map { |f| File.basename(f) }.sort - ['flow_index.json']
end

# flows/ documents nothing in flow_index.json references (the M3 sweep's
# target state: none).
def orphaned_flow_documents(output_dir)
  referenced = flow_index(output_dir).values.map { |path| File.basename(path) }
  flow_documents(output_dir) - referenced
end

# One controller's slice of flow_index.json as { action => relative path } —
# the same shape the unit's metadata.flow_paths annotation carries.
def controller_flow_paths(index, identifier)
  index.each_with_object({}) do |(entry_point, path), map|
    owner, action = entry_point.split('#', 2)
    map[action] = path if owner == identifier
  end
end

def controller_unit_json(output_dir, identifier)
  dir = payload_dir(output_dir).join('controllers')
  candidates = Dir[dir.join("#{Woods::FilenameUtils.safe_segment(identifier)}_*.json")]
  raise "no unit file for #{identifier} under #{dir}" if candidates.empty?

  JSON.parse(File.read(candidates.first))
end

def controller_annotation(output_dir, identifier)
  controller_unit_json(output_dir, identifier).dig('metadata', 'flow_paths') || {}
end

def controller_index_tokens(output_dir, identifier)
  entries = JSON.parse(payload_dir(output_dir).join('controllers', '_index.json').read)
  entry = entries.find { |e| e['identifier'] == identifier }
  raise "#{identifier} missing from controllers/_index.json" if entry.nil?

  entry['estimated_tokens']
end

# The real `woods:validate` task, in-process: load_tasks registers the
# engine's rake file, reenable lets the smoke invoke it repeatedly, and the
# task's own `exit 1` on errors surfaces here as SystemExit — captured and
# turned into a boolean instead of killing the runner. Output is captured
# too, so a failure can show the validator's own report.
def woods_validate
  original_stdout = $stdout
  @flows_smoke_tasks_loaded ||= Rails.application.load_tasks
  task = Rake::Task['woods:validate']
  task.reenable
  captured = StringIO.new
  $stdout = captured
  task.invoke
  [true, captured.string]
rescue SystemExit => e
  [e.success?, captured.string]
ensure
  $stdout = original_stdout if original_stdout
end

# ── Controller-edit helpers ──────────────────────────────────────────────
# The fixture edit: one trivial public action appended inside the class
# body (before the final column-0 `end`), removed again by restoring the
# original bytes. The app directory is bind-mounted read-write, so the
# edit is visible to the leg's fresh boot; the restore makes the whole
# exercise net-zero for the tree.

def insert_probe_action(path)
  content = File.read(path)
  # Insert directly under the class opening: appending before the final
  # `end` would land after a trailing `private` (the tutorial controllers
  # have one), and a private method is not an action — action_methods
  # only lists public instance methods.
  opener = content.match(/^class\s+.*\n/)
  raise "no class-opening line in #{path} — cannot insert #{PROBE_ACTION}" if opener.nil?

  File.write(path, "#{opener[0]}\n  def #{PROBE_ACTION}\n    head :ok\n  end\n#{content[opener.end(0)..]}")
end

# One fresh-boot incremental for a single changed path: the documented CI
# invocation (`CHANGED_FILES` + `woods:incremental`), so the delta runs in
# a boot whose autoloaded constants reflect the edited file.
LEG_INITIALIZER = 'config/initializers/zzz_woods_flows_smoke_precompute.rb'

def write_leg_initializer
  return if Rails.root.join(LEG_INITIALIZER).file?

  File.write(Rails.root.join(LEG_INITIALIZER), <<~RUBY)
    # frozen_string_literal: true

    # Transient: written by script/shared/woods_flows_smoke.rb so its
    # `woods:incremental` leg boots with flow precomputation enabled
    # (the knob has no env override). Deleted by the smoke's ensure.
    Woods.configure { |c| c.precompute_flows = true }
  RUBY
end

def remove_leg_initializer
  path = Rails.root.join(LEG_INITIALIZER)
  File.delete(path) if path.file?
end

def run_incremental_leg(output_dir, relative_path)
  stdout, stderr, status = Open3.capture3(
    { 'CHANGED_FILES' => relative_path, 'WOODS_OUTPUT' => output_dir, 'WOODS_IGNORE_WATCH' => '1' },
    File.join(Rails.root.to_s, 'bin/rails'), 'woods:incremental',
    chdir: Rails.root.to_s
  )
  [stdout, stderr, status]
end

# ── Section 1: full extraction publishes the flows family (G-2) ──────────

puts '=== Section 1: full extraction with precompute_flows publishes a valid flows family ==='

results << assert('precompute_flows is enabled for the run') do
  raise 'Woods.configuration.precompute_flows is false' unless Woods.configuration.precompute_flows
end

results << assert('full extraction completes') do
  Woods::Extractor.new(output_dir: output_dir).extract_all
end

results << assert('flows/ family present in the published payload') do
  dir = flows_dir(output_dir)
  raise "no flows/ directory under #{payload_dir(output_dir)}" unless dir.directory?
  raise 'flows/ is empty' if Dir[dir.join('*.json')].empty?
end

results << assert('flow_index.json exists and parses with entries for controller actions') do
  index = flow_index(output_dir)
  raise 'flow_index.json is empty' if index.empty?

  raise 'entries are not entry_point => relative path' unless index.values.all? { |v| v.start_with?('flows/') }
end

results << assert('every referenced flow document exists and parses') do
  index = flow_index(output_dir)
  # Index values are output_dir-relative ("flows/X.json"), the same base
  # woods:validate joins against — not the flows/ directory itself.
  base = payload_dir(output_dir)
  index.each do |entry_point, relative|
    document = base.join(relative)
    raise "#{entry_point} references missing document #{relative}" unless document.file?

    JSON.parse(document.read)
  end
end

validate_ok, validate_out = woods_validate
results << assert('woods:validate passes with the flows family present (G-2)') do
  raise "woods:validate failed:\n#{validate_out}" unless validate_ok
end

results << assert('validator reports no legacy "Missing _index.json in flows/" failure') do
  raise "legacy flows-family failure resurfaced:\n#{validate_out}" if validate_out.include?('Missing _index.json in flows/')
end

# ── Sections 2 and 3: guarded region ─────────────────────────────────────
# Per-assert failures are captured by `assert`; this outer rescue covers
# the plumbing around them (file edits, baseline reads, leg spawns) so an
# unexpected raise still prints a FAIL line and the summary. The fixture
# file is restored on the way out either way.
post_incremental_index = nil

begin
  # Baselines Sections 2 and 3 compare against.
  baseline_index     = flow_index(output_dir)
  baseline_documents = flow_documents(output_dir)
  flow_index_entry_points = baseline_index.keys.group_by { |entry_point| entry_point.split('#', 2).first }

  # The controller the incremental legs touch: the one with the most flow
  # entries whose unit file still exists (most observable delta per edit),
  # alphabetical tie-break for determinism. Its recorded file_path drives
  # both the edit and the leg's CHANGED_FILES value. Defensive on purpose:
  # a variant whose index carries a controller with no readable unit falls
  # out of the candidate list instead of aborting the smoke.
  candidates = flow_index_entry_points.filter_map do |id, entries|
    unit = begin
      controller_unit_json(output_dir, id)
    rescue StandardError
      nil
    end
    next nil if unit.nil? || unit['file_path'].blank?

    [id, entries, unit['file_path'].to_s]
  end
  chosen_identifier, chosen_entries, chosen_file = candidates
                                                  .sort_by { |id, entries, _| [-entries.size, id] }
                                                  .first
  chosen_relative = chosen_file.to_s.sub(%r{\A#{Regexp.escape(Rails.root.to_s)}/}, '')
  chosen_path     = Rails.root.join(chosen_relative)

  if chosen_identifier.nil? || !chosen_path.file?
    reason = chosen_identifier.nil? ? 'no controller with flow entries and a readable unit' \
                                    : "#{chosen_identifier}'s recorded file #{chosen_relative} does not exist"
    puts "  FAIL  cannot run the incremental legs: #{reason}"
    results << false
  else
    baseline_annotation = controller_annotation(output_dir, chosen_identifier)
    baseline_tokens     = controller_index_tokens(output_dir, chosen_identifier)

    # ── Section 2: incremental legs keep the family coherent (M3) ────────

    puts
    puts "=== Section 2: incremental legs on #{chosen_relative} (#{chosen_entries.size} flow entries) ==="

    original_content = File.read(chosen_path)
    write_leg_initializer
    begin
      # Leg A: add the probe action, incremental, expect it mapped end to
      # end.
      insert_probe_action(chosen_path)
      out, err, status = run_incremental_leg(output_dir, chosen_relative)

      results << assert('incremental leg (action added) exits 0') do
        raise "exit #{status.exitstatus}\n#{out}#{err}" unless status.success?
      end

      results << assert("incremental leg re-extracted #{chosen_identifier}") do
        # woods:incremental reports the run in two lines; the delta's
        # effect on this controller is asserted against the payload below.
        raise "leg did not report an incremental extraction; stdout:\n#{out}#{err}" unless out.match?(/Incremental extraction for \d+ changed file/) && out.match?(/Re-extracted \d+ affected units/)
      end

      after_add = flow_index(output_dir)
      removed_relative = after_add["#{chosen_identifier}##{PROBE_ACTION}"]

      results << assert("flow_index.json gains #{chosen_identifier}##{PROBE_ACTION}") do
        raise "entries for #{chosen_identifier}: #{controller_flow_paths(after_add, chosen_identifier).keys.inspect}" if removed_relative.nil?
      end

      results << assert('the added action has a flow document on disk and it parses') do
        raise "#{PROBE_ACTION} never mapped — nothing to read" if removed_relative.nil?

        document = payload_dir(output_dir).join(removed_relative)
        raise "missing #{removed_relative}" unless document.file?

        JSON.parse(document.read)
      end

      results << assert("the re-extracted unit's flow_paths annotation carries #{PROBE_ACTION}") do
        annotation = controller_annotation(output_dir, chosen_identifier)
        raise "annotation actions: #{annotation.keys.inspect}" unless annotation.key?(PROBE_ACTION)
      end

      results << assert('unit annotation matches flow_index.json for the touched controller') do
        annotation = controller_annotation(output_dir, chosen_identifier)
        indexed    = controller_flow_paths(after_add, chosen_identifier)
        raise "annotation #{annotation.inspect} != index #{indexed.inspect}" unless annotation == indexed
      end

      results << assert('controllers/_index.json re-derived after the annotation patch (estimated_tokens moved)') do
        tokens = controller_index_tokens(output_dir, chosen_identifier)
        raise "estimated_tokens unchanged at #{tokens.inspect}" if tokens == baseline_tokens
      end

      results << assert('no orphaned flow documents after the add') do
        orphans = orphaned_flow_documents(output_dir)
        raise "orphans: #{orphans.inspect}" unless orphans.empty?
      end

      validate_ok, validate_out = woods_validate
      results << assert('woods:validate passes after the add') do
        raise "woods:validate failed:\n#{validate_out}" unless validate_ok
      end

      # Leg B: restore the original bytes — the probe action is now a
      # removed action — incremental, expect the entry gone and the
      # document swept. Touched controllers replace their entries
      # wholesale, so this is exactly the delta contract's removed-action
      # shape.
      File.write(chosen_path, original_content)
      out, err, status = run_incremental_leg(output_dir, chosen_relative)

      results << assert('incremental leg (action removed) exits 0') do
        raise "exit #{status.exitstatus}\n#{out}#{err}" unless status.success?
      end

      results << assert("flow_index.json no longer lists #{PROBE_ACTION} for #{chosen_identifier}") do
        index = flow_index(output_dir)
        raise "entry survived: #{index["#{chosen_identifier}##{PROBE_ACTION}"].inspect}" if index.key?("#{chosen_identifier}##{PROBE_ACTION}")
      end

      results << assert("the removed action's flow document was swept") do
        raise "#{PROBE_ACTION} was never mapped — sweep unobservable" if removed_relative.nil?

        document = payload_dir(output_dir).join(removed_relative)
        raise "#{removed_relative} still on disk" if document.file?
      end

      results << assert("unit annotation returns to the pre-edit map for #{chosen_identifier}") do
        annotation = controller_annotation(output_dir, chosen_identifier)
        raise "annotation #{annotation.inspect} != baseline #{baseline_annotation.inspect}" unless annotation == baseline_annotation
      end

      results << assert('controllers/_index.json estimated_tokens return to the pre-edit value') do
        tokens = controller_index_tokens(output_dir, chosen_identifier)
        raise "estimated_tokens #{tokens.inspect} != baseline #{baseline_tokens.inspect}" unless tokens == baseline_tokens
      end

      results << assert('no orphaned flow documents after the removal') do
        orphans = orphaned_flow_documents(output_dir)
        raise "orphans: #{orphans.inspect}" unless orphans.empty?
      end

      validate_ok, validate_out = woods_validate
      results << assert('woods:validate passes after the removal') do
        raise "woods:validate failed:\n#{validate_out}" unless validate_ok
      end

      post_incremental_index = flow_index(output_dir)
    ensure
      File.write(chosen_path, original_content) if File.read(chosen_path) != original_content
      remove_leg_initializer
    end

    # ── Section 3: full-vs-incremental flow inventory equivalence (M3) ────

    puts
    puts '=== Section 3: full extraction reproduces the incremental flow inventory ==='

    results << assert('full extraction completes again') do
      Woods::Extractor.new(output_dir: output_dir).extract_all
    end

    full_index = flow_index(output_dir)

    results << assert("full extraction flow inventory equals the incremental run's") do
      raise 'incremental leg never produced a readable index' if post_incremental_index.nil?

      unless full_index == post_incremental_index
        raise "entry points differ (full-only: #{(full_index.keys - post_incremental_index.keys).inspect}, " \
              "incremental-only: #{(post_incremental_index.keys - full_index.keys).inspect}); " \
              "value drift: #{(full_index.to_a - post_incremental_index.to_a).inspect}"
      end
    end

    results << assert('full extraction flow inventory equals the original baseline') do
      raise "baseline drift: #{(full_index.to_a - baseline_index.to_a).inspect}" unless full_index == baseline_index
    end

    results << assert('flow document set matches the index exactly (no orphans, no missing)') do
      referenced   = full_index.values.map { |path| File.basename(path) }.sort
      on_disk      = flow_documents(output_dir)
      unreferenced = on_disk - referenced
      missing      = referenced - on_disk
      raise "unreferenced: #{unreferenced.inspect}; missing: #{missing.inspect}" unless unreferenced.empty? && missing.empty?
    end

    results << assert("controllers annotation for #{chosen_identifier} matches the baseline") do
      annotation = controller_annotation(output_dir, chosen_identifier)
      raise "annotation #{annotation.inspect} != baseline #{baseline_annotation.inspect}" unless annotation == baseline_annotation
    end

    results << assert('baseline flow documents all survived the round trip') do
      drifted = baseline_documents - flow_documents(output_dir)
      raise "lost: #{drifted.inspect}" unless drifted.empty?
    end
  end
rescue StandardError => e
  results << false
  puts "  FAIL  smoke aborted: #{e.class}: #{e.message}"
end

# ── Summary ──────────────────────────────────────────────────────────────

puts
puts '=== Summary ==='
passed = results.count(true)
failed = results.count(false)
puts "passed: #{passed}    failed: #{failed}    total: #{results.size}"
exit(failed.zero? ? 0 : 1)
