# frozen_string_literal: true

# Incremental-vs-full equivalence under each `incremental_blast_radius_depth`
# setting (unbounded nil, a depth of 1, :structural), on Canopy.
#
#   bin/rails runner script/shared/tools/blast_radius_compare.rb
#
# Every cell runs in its own disposable copy of the application: a full
# extract of the base, one change, an incremental run with CHANGED_FILES set
# to exactly the changed files, then a full extract of the changed tree into a
# second output directory. The interactive working tree is never modified.
#
# Environment:
#   BRC_CONFIGS  comma-separated subset of nil,1,structural (default all)
#   BRC_CHANGES  comma-separated subset of change keys (default all)
#   BRC_CONTROL  0 skips the full-vs-full control
#   BRC_KEEP     1 keeps the tmpdirs (prints their paths)
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'set'

raise 'Canopy required' unless Rails.root.join('functional_contract.yml').file?

module BlastRadiusCompare
  module_function

  COPY = %w[app config lib spec bin Gemfile Gemfile.lock Rakefile config.ru].freeze

  # Leaf paths that differ between two full extractions of one tree, found by
  # the control. A path is the payload category, then the JSON key path with
  # array indices written as []. Filled from the control's own output.
  NOISE = [].freeze
  # Per-extractor wall times: the control shows every timing varies, and an
  # incremental run times only the extractors it ran.
  NOISE_PREFIXES = %w[manifest.json.extractor_timings.].freeze

  CONFIGS = { 'nil' => 'nil', '1' => '1', 'structural' => ':structural' }.freeze

  def sub!(root, rel, from, to)
    path = File.join(root, rel)
    src = File.read(path)
    raise "#{rel}: pattern not found: #{from.inspect}" unless src.include?(from)

    File.write(path, src.sub(from, to))
    rel
  end

  # The base every cell starts from: Canopy plus a three-level payment STI
  # chain and a nested has_many :through (Collection -> Article -> ArticleTag).
  def prepare_base(root)
    File.write(File.join(root, 'app/models/billing/corporate_card_payment.rb'), <<~RUBY)
      module Billing
        # Third STI level: Payment > CardPayment > CorporateCardPayment.
        class CorporateCardPayment < CardPayment
          validates :last_four, length: { is: 4 }
        end
      end
    RUBY
    sub!(root, 'app/models/collection.rb',
         "  has_many :articles, through: :collection_articles\n",
         "  has_many :articles, through: :collection_articles\n  has_many :tags, through: :articles\n")
  end

  CHANGES = {
    'association' => lambda do |root|
      [sub!(root, 'app/models/author.rb', "  has_many :articles, dependent: :destroy\n",
            "  has_many :articles, dependent: :destroy\n  has_many :curated_tags, class_name: 'Tag', " \
            "foreign_key: :curator_id, inverse_of: :curator, dependent: :nullify\n"),
       sub!(root, 'app/models/tag.rb', "  has_many :articles, through: :article_tags\n",
            "  has_many :articles, through: :article_tags\n  belongs_to :curator, class_name: 'Author', " \
            "optional: true, inverse_of: :curated_tags\n")]
    end,
    'rename' => lambda do |root|
      files = Dir.chdir(root) { Dir.glob('{app,lib}/**/*.rb').select { |f| File.read(f).include?('editor_of?') } }.sort
      raise 'rename: fewer than three files' if files.size < 3

      files.each do |rel|
        path = File.join(root, rel)
        File.write(path, File.read(path).gsub('editor_of?', 'can_edit_for?'))
      end
      files
    end,
    'sti_root' => lambda do |root|
      [sub!(root, 'app/models/billing/payment.rb',
            "    validates :amount_cents, numericality: { greater_than: 0 }\n",
            "    validates :amount_cents, numericality: { greater_than: 0 }\n    validates :state, presence: true\n" \
            "    scope :large, -> { where('amount_cents > 10000') }\n")]
    end,
    'nested_through' => lambda do |root|
      [sub!(root, 'app/models/article_tag.rb', "  belongs_to :tag\n", "  belongs_to :tag, foreign_key: :tag_ref_id\n")]
    end,
    'mixin' => lambda do |root|
      [sub!(root, 'app/models/concerns/archivable.rb', "    archived_at.present?\n",
            "    archived_at.present? && archived_at <= Time.current\n")]
    end
  }.freeze

  def database
    File.expand_path(ActiveRecord::Base.connection_db_config.database, Rails.root)
  end

  def run(root, task, output, changed: nil, profile: false)
    env = { 'BUNDLE_GEMFILE' => File.join(root, 'Gemfile'), 'DATABASE_URL' => "sqlite3:#{database}",
            'WOODS_OUTPUT' => output, 'CHANGED_FILES' => changed&.join(','),
            'WOODS_PROFILE' => profile ? '1' : nil }
    FileUtils.rm_rf(File.join(root, 'tmp/cache/bootsnap'))
    log_path = File.join(root, 'log/development.log')
    FileUtils.rm_f(log_path)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, status = Open3.capture2e(env, 'bundle', 'exec', 'ruby', 'bin/rails', task, chdir: root)
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    raise "#{task} failed in #{root}:\n#{out.lines.last(25).join}" unless status.success?

    log = File.file?(log_path) ? File.read(log_path) : ''
    { wall: wall.round(1), out: out, log: log }
  end

  def payload_dir(output)
    File.join(output, JSON.parse(File.read(File.join(output, 'generation.json'))).fetch('payload'))
  end

  # A unit payload is any JSON object carrying identifier and type outside
  # flows/, wherever it sits; a flow document is anything under flows/.
  def category(rel, content = nil)
    return 'flow' if rel.start_with?('flows/')
    return 'unit' if content.is_a?(Hash) && content.key?('identifier') && content.key?('type')

    'other'
  end

  def files(dir)
    Dir.chdir(dir) { Dir.glob('**/*', File::FNM_DOTMATCH).select { |f| File.file?(f) } }.sort
  end

  def leaves(a, b, path = [], acc = [])
    if a.is_a?(Hash) && b.is_a?(Hash)
      (a.keys | b.keys).each { |k| leaves(a[k], b[k], path + [k.to_s], acc) }
    elsif a.is_a?(Array) && b.is_a?(Array) && a.size == b.size
      a.each_index { |i| leaves(a[i], b[i], path + [i], acc) }
    elsif a != b
      acc << [path, a, b]
    end
    acc
  end

  def pattern(rel, path)
    head = if @units.include?(rel) then 'unit'
           elsif rel.start_with?('flows/') then 'flows/*.json'
           else rel
           end
    ([head] + path.map { |p| p.is_a?(Integer) ? '[]' : p }).join('.')
  end

  def noise?(rel, path, noise)
    key = pattern(rel, path)
    noise.include?(key) || NOISE_PREFIXES.any? { |prefix| key.start_with?(prefix) }
  end

  def read(dir, rel)
    raw = File.read(File.join(dir, rel))
    # SUMMARY.md stamps its generation time; the rest of it is content.
    return raw.sub(/^Generated: .*$/, 'Generated: <time>') if rel.end_with?('SUMMARY.md')

    rel.end_with?('.json') ? JSON.parse(raw) : raw
  rescue JSON::ParserError
    raw
  end

  # @return [Hash] rel => { category:, type:, leaves: [[path, a, b]] }
  def compare(dir_a, dir_b, noise)
    @units ||= Set.new
    fa = files(dir_a)
    fb = files(dir_b)
    (fa | fb).each_with_object({}) do |rel, diffs|
      a = fa.include?(rel) ? read(dir_a, rel) : :missing
      b = fb.include?(rel) ? read(dir_b, rel) : :missing
      cat = category(rel, [a, b].find { |x| x.is_a?(Hash) })
      @units << rel if cat == 'unit'
      found = a == :missing || b == :missing ? [[['<file>'], a == :missing ? 'missing' : 'present', b == :missing ? 'missing' : 'present']] : leaves(a, b)
      found = found.reject { |path, _, _| noise?(rel, path, noise) }
      next if found.empty?

      unit = [a, b].find { |x| x.is_a?(Hash) }
      diffs[rel] = { category: cat, type: unit&.fetch('type', nil), identifier: unit&.fetch('identifier', nil), leaves: found }
    end
  end

  def brief(value)
    s = value.to_json
    s.size > 160 ? "#{s[0, 160]}…" : s
  end

  def summarize(diffs, cat)
    picked = diffs.select { |_, d| d[:category] == cat }
    types = picked.values.group_by { |d| d[:type] || '?' }.transform_values(&:size)
    [picked.size, types]
  end

  def copy_app(dir)
    COPY.each { |name| FileUtils.cp_r(Rails.root.join(name), dir) if Rails.root.join(name).exist? }
    FileUtils.mkdir_p(File.join(dir, 'db'))
    FileUtils.cp(Rails.root.join('db/schema.rb'), File.join(dir, 'db/schema.rb'))
  end

  def configure(root, depth)
    File.write(File.join(root, 'config/initializers/zz_blast_radius.rb'), <<~RUBY)
      # frozen_string_literal: true
      Woods.configure do |config|
        config.incremental_blast_radius_depth = #{depth}
        config.precompute_flows = true
      end
    RUBY
  end

  def detail(diffs, limit: 6)
    diffs.map do |rel, d|
      shown = d[:leaves].first(limit).map { |path, a, b| "      #{path.join('.')}: #{brief(a)} -> #{brief(b)}" }
      more = d[:leaves].size > limit ? ["      … #{d[:leaves].size - limit} more"] : []
      (["    #{rel} [#{d[:category]} #{d[:type]}]"] + shown + more).join("\n")
    end.join("\n")
  end
end

brc = BlastRadiusCompare
keep = ENV['BRC_KEEP'] == '1'
configs = (ENV['BRC_CONFIGS'] || 'nil,1,structural').split(',')
changes = (ENV['BRC_CHANGES'] || brc::CHANGES.keys.join(',')).split(',')
tmpdirs = []
rows = []

begin
  template = Dir.mktmpdir('brc-base-')
  tmpdirs << template
  brc.copy_app(template)
  brc.prepare_base(template)

  noise = brc::NOISE
  if ENV['BRC_CONTROL'] != '0'
    cell = Dir.mktmpdir('brc-control-')
    tmpdirs << cell
    FileUtils.cp_r(File.join(template, '.'), cell)
    brc.configure(cell, ':structural')
    out_a = File.join(cell, 'tmp/woods_a')
    out_b = File.join(cell, 'tmp/woods_b')
    brc.run(cell, 'woods:extract', out_a)
    brc.run(cell, 'woods:extract', out_a)
    brc.run(cell, 'woods:extract', out_b)
    raw = brc.compare(brc.payload_dir(out_a), brc.payload_dir(out_b), [])
    observed = raw.flat_map { |rel, d| d[:leaves].map { |path, _, _| brc.pattern(rel, path) } }.uniq.sort
    puts '== control: full (gen 2) vs full (gen 1), same tree'
    puts "  files differing: #{raw.size}; distinct leaf patterns: #{observed.size}"
    observed.each { |p| puts "    NOISE #{p}" }
    puts brc.detail(raw.first(8).to_h, limit: 3)
    noise = (noise + observed).uniq
  end

  changes.each do |change|
    configs.each do |config|
      cell = Dir.mktmpdir("brc-#{change}-#{config}-")
      tmpdirs << cell
      FileUtils.cp_r(File.join(template, '.'), cell)
      brc.configure(cell, brc::CONFIGS.fetch(config))
      out_inc = File.join(cell, 'tmp/woods_inc')
      out_full = File.join(cell, 'tmp/woods_full')
      base = brc.run(cell, 'woods:extract', out_inc)
      base_dir = brc.payload_dir(out_inc)
      changed = brc::CHANGES.fetch(change).call(cell)
      inc = brc.run(cell, 'woods:incremental', out_inc, changed: changed, profile: true)
      full = brc.run(cell, 'woods:extract', out_full)
      inc_dir = brc.payload_dir(out_inc)
      raise "#{change}/#{config}: incremental did not publish" if inc_dir == base_dir

      diffs = brc.compare(inc_dir, brc.payload_dir(out_full), noise)
      truth = brc.compare(base_dir, brc.payload_dir(out_full), noise)
      rewritten = brc.compare(base_dir, inc_dir, noise)
      radius = inc[:log][/(\d+) changed files? affects? (\d+) units?/, 2]
      reextracted = inc[:log].scan(/\[Woods\] Re-extracted (\S+)/).flatten.uniq
      phase = inc[:log][/\[profile\] blast radius in ([\d.]+)s/, 1]
      units_n, unit_types = brc.summarize(diffs, 'unit')
      flows_n, = brc.summarize(diffs, 'flow')
      other_n, = brc.summarize(diffs, 'other')
      truth_units, truth_types = brc.summarize(truth, 'unit')
      truth_flows, = brc.summarize(truth, 'flow')
      rw_units, = brc.summarize(rewritten, 'unit')
      row = { change: change, config: config, changed: changed, inc_wall: inc[:wall], full_wall: full[:wall],
              base_wall: base[:wall], radius: radius, reextracted: reextracted.size, rewritten_units: rw_units,
              radius_phase_s: phase, unit_diffs: units_n, unit_diff_types: unit_types, flow_diffs: flows_n,
              other_diffs: other_n, true_unit_delta: truth_units, true_unit_delta_types: truth_types,
              true_flow_delta: truth_flows }
      rows << row
      puts "== #{change} / #{config}: #{row.except(:changed).to_json}"
      puts "  changed: #{changed.join(',')}"
      puts brc.detail(diffs) unless diffs.empty?
      puts "  KEPT #{cell}" if keep
    end
  end
ensure
  tmpdirs.each { |dir| FileUtils.rm_rf(dir) } unless keep
end

puts
puts '| change | config | inc wall | full wall | radius | re-extracted | units rewritten | payloads differing | flows differing | other differing | true delta (units/flows) |'
puts '|---|---|---|---|---|---|---|---|---|---|---|'
rows.each do |r|
  types = r[:unit_diff_types].map { |t, n| "#{t}:#{n}" }.join(' ')
  puts "| #{r[:change]} | #{r[:config]} | #{r[:inc_wall]}s | #{r[:full_wall]}s | #{r[:radius]} | #{r[:reextracted]} | " \
       "#{r[:rewritten_units]} | #{r[:unit_diffs]}#{" (#{types})" unless types.empty?} | #{r[:flow_diffs]} | " \
       "#{r[:other_diffs]} | #{r[:true_unit_delta]}/#{r[:true_flow_delta]} |"
end
puts "BRC_JSON #{rows.to_json}"
