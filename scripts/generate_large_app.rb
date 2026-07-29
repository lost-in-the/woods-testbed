# frozen_string_literal: true

# Run with:  bin/rails runner script/shared/generate_large_app.rb
#        or: ruby script/shared/generate_large_app.rb   (no Rails needed)
#
# Generates the multiplied half of apps/rails-8.0-large: thousands of units with
# realistic association density, from a committed generator so the tree is
# reproducible rather than a vendored giant.
#
# Why generated rather than vendored (woods-testbed#2): a committed 5,000-file
# Rails app is unreviewable and poisons every future diff. The reproducibility a
# committed tree would buy is recovered by writing a manifest with the generator
# version, the scale, and a checksum of the emitted tree — so a benchmark number
# from six months ago is self-describing.
#
# DETERMINISM IS THE POINT. Same scale in, byte-identical tree out:
#   - seeded PRNG, never Kernel#rand
#   - no timestamps anywhere in the output
#   - sorted iteration everywhere
# The manifest checksum is what proves it; `--verify` regenerates into a temp
# directory and compares.
#
# Scale:
#   WOODS_GEN_SCALE=small     20 families   — CI
#   WOODS_GEN_SCALE=medium   200 families
#   WOODS_GEN_SCALE=large    875 families   — targets the ~6-8k unit band that
#                                             makes the whole-app re-run
#                                             percentage comparable to the
#                                             ~7,100-unit host in #2
#   WOODS_GEN_SCALE=<int>    that many families
#
# Everything it writes carries the `Gen` prefix and lives under app/generated,
# db/generated and config/routes_generated.rb — all gitignored. The prefix is
# per the kernel contract: it keeps generated identifiers from ever colliding
# with kernel ones, which matters because DependencyGraph keys nodes on the bare
# identifier (woods B-062).
#
# Usage:
#   ruby generate_large_app.rb            # generate at WOODS_GEN_SCALE
#   ruby generate_large_app.rb --clean    # remove the generated tree
#   ruby generate_large_app.rb --verify   # generate twice, assert identical

require 'digest'
require 'fileutils'
require 'json'
require 'pathname'

GENERATOR_VERSION = 1

PRESETS = { 'small' => 20, 'medium' => 200, 'large' => 875 }.freeze

# Fixed seed. Changing it changes every generated name, which invalidates
# comparison with previously recorded numbers — treat it as part of the
# generator version.
SEED = 20_260_729

APP_ROOT = Pathname.new(ENV['WOODS_GEN_APP_ROOT'] || Dir.pwd)

# Emitted into the REAL directories, not a single app/generated tree.
#
# That is load-bearing: the file-based extractors scan fixed directory lists
# (ServiceExtractor looks at app/services|use_cases|operations|..., the view
# extractor at app/views). A tidy app/generated/use_cases would never be found,
# so only the class-based types would multiply and the generated tree would
# exercise a fraction of the extractor surface it is supposed to stress.
#
# Zeitwerk would normally read `generated/` as a namespace segment, so
# config/application.rb collapses these directories.
GENERATED_PATHS = [
  'app/models/generated',
  'app/models/concerns/generated',
  'app/controllers/generated',
  'app/use_cases/generated',
  'app/jobs/generated',
  'app/views/generated',
  'db/generated',
  'config/routes_generated.rb',
  'tmp/generated_manifest.json'
].freeze

def scale_from_env
  raw = ENV.fetch('WOODS_GEN_SCALE', 'small')
  PRESETS[raw] || Integer(raw)
rescue ArgumentError
  abort "WOODS_GEN_SCALE must be one of #{PRESETS.keys.join(', ')} or an integer, got #{raw.inspect}"
end

def clean!
  GENERATED_PATHS.each { |p| FileUtils.rm_rf(APP_ROOT.join(p)) }
  puts "removed the generated tree under #{APP_ROOT}"
end

# ── Naming ────────────────────────────────────────────────────────────────
# Names come from a fixed word list indexed arithmetically rather than sampled,
# so family N always has the same name regardless of scale. That means a
# medium tree is a strict superset of a small one, and a number measured at one
# scale stays interpretable at another.
NOUNS = %w[
  ledger parcel invoice route beacon anchor ember harbor lantern meadow
  quarry ribbon summit thicket vellum willow cinder dapple fathom girder
].freeze

def family_name(index)
  "#{NOUNS[index % NOUNS.size].capitalize}#{index / NOUNS.size}"
end

# ── Association topology ──────────────────────────────────────────────────
# Not a flat pile: each family belongs_to a hub chosen from a small set, so the
# graph has genuine fan-in for PageRank to rank and for the dependents pass to
# resolve. A deterministic minority also point at a sibling, which introduces
# cycles — the graph must survive them (DependencyGraph#visited).
HUB_COUNT = 8

def hub_for(index)
  "GenHub#{index % HUB_COUNT}"
end

def sibling_for(index, total)
  return nil unless (index % 7).zero?

  other = (index + 3) % total
  other == index ? nil : family_name(other)
end

def write(path, body)
  full = APP_ROOT.join(path)
  FileUtils.mkdir_p(full.dirname)
  full.write(body)
end

def generate!(scale) # rubocop:disable Metrics/MethodLength
  rng = Random.new(SEED)
  clean!

  hubs = (0...HUB_COUNT).map { |i| "GenHub#{i}" }
  families = (0...scale).map { |i| family_name(i) }

  # ── Hubs ────────────────────────────────────────────────────────────────
  hubs.each do |hub|
    write "app/models/generated/#{hub.gsub(/([a-z])([A-Z0-9])/, '\1_\2').downcase}.rb", <<~RUBY
      class #{hub} < ApplicationRecord
        self.table_name = "gen_hubs"

        has_many :gen_records, class_name: "GenRecord", foreign_key: :hub_id, dependent: :destroy

        validates :name, presence: true

        scope :active, -> { where(active: true) }
      end
    RUBY
  end

  # A single backing table for every generated family keeps the schema small
  # while the models stay real ActiveRecord classes with real columns — which is
  # what ModelExtractor needs (a model whose table_exists? is false is dropped).
  write 'app/models/generated/gen_record.rb', <<~RUBY
    class GenRecord < ApplicationRecord
      self.table_name = "gen_records"

      belongs_to :hub, class_name: "GenHub0", foreign_key: :hub_id, optional: true
    end
  RUBY

  families.each_with_index do |name, index|
    snake = name.gsub(/([a-z])([A-Z0-9])/, '\1_\2').downcase
    hub = hub_for(index)
    sibling = sibling_for(index, families.size)
    cache = (index % 5).zero?

    write "app/models/generated/#{snake}.rb", <<~RUBY
      class #{name} < ApplicationRecord
        include GenArchivable

        self.table_name = "gen_records"

        belongs_to :hub, class_name: "#{hub}", foreign_key: :hub_id, optional: true
        #{sibling ? %(has_many :#{sibling.downcase}_links, class_name: "#{sibling}", foreign_key: :hub_id) : ''}

        validates :name, presence: true

        scope :recent, -> { order(created_at: :desc) }

        def summary
          "#{name}: \#{name}"
        end
      end
    RUBY

    write "app/controllers/generated/#{snake}_controller.rb", <<~RUBY
      class #{name}Controller < ApplicationController
        def index
          #{if cache
              %(@records = Rails.cache.fetch("#{snake}/index") { #{name}.recent.to_a })
            else
              %(@records = #{name}.recent)
            end}
        end

        def show
          @record = #{name}.find(params[:id])
        end
      end
    RUBY

    write "app/use_cases/generated/process_#{snake}.rb", <<~RUBY
      class Process#{name}
        def initialize(record)
          @record = record
        end

        def call
          Refresh#{name}Job.perform_later(@record.id)
          @record
        end
      end
    RUBY

    write "app/jobs/generated/refresh_#{snake}_job.rb", <<~RUBY
      class Refresh#{name}Job < ApplicationJob
        queue_as :generated

        def perform(record_id)
          #{name}.find(record_id).touch
        end
      end
    RUBY

    # Route helpers here are what RouteHelperResolver turns into navigation
    # edges, so the generated tree exercises the same fan-out the kernel does.
    write "app/views/generated/#{snake}/index.html.erb", <<~ERB
      <h1>#{name}</h1>
      <ul>
        <% @records.each do |record| %>
          <li><%= link_to record.name, gen_#{snake}_path(record) %></li>
        <% end %>
      </ul>
    ERB

    write "app/views/generated/#{snake}/show.html.erb", <<~ERB
      <h1><%= @record.name %></h1>
      <%= link_to "All", gen_#{snake}_index_path %>
    ERB
  end

  # Shared concern, included by every generated model — the wholesale
  # re-extraction path cares about how many units a single file reaches.
  write 'app/models/concerns/generated/gen_archivable.rb', <<~RUBY
    module GenArchivable
      extend ActiveSupport::Concern

      included do
        scope :gen_archived, -> { where.not(archived_at: nil) }
      end

      def gen_archive!
        update!(archived_at: Time.current)
      end
    end
  RUBY

  # ── Routes ──────────────────────────────────────────────────────────────
  routes = families.map do |name|
    snake = name.gsub(/([a-z])([A-Z0-9])/, '\1_\2').downcase
    %(  resources :gen_#{snake}, only: %i[index show], controller: "#{snake}")
  end
  write 'config/routes_generated.rb', <<~RUBY
    # Drawn from config/routes.rb. Regenerated by scripts/generate_large_app.rb.
    Rails.application.routes.draw do
    #{routes.join("\n")}
    end
  RUBY

  # ── Migration for the two backing tables ────────────────────────────────
  write 'db/generated/migrate/20260201000001_create_generated_tables.rb', <<~RUBY
    class CreateGeneratedTables < ActiveRecord::Migration[8.0]
      def change
        create_table :gen_hubs do |t|
          t.string :name, null: false
          t.boolean :active, default: true, null: false
          t.timestamps
        end

        create_table :gen_records do |t|
          t.integer :hub_id
          t.string :name, null: false
          t.datetime :archived_at
          t.timestamps
          t.index [:hub_id]
        end
      end
    end
  RUBY

  emitted = GENERATED_PATHS
            .reject { |p| p.start_with?('tmp/') }
            .flat_map { |p| Dir[APP_ROOT.join(p), APP_ROOT.join(p, '**/*')] }
            .select { |f| File.file?(f) }
            .uniq
            .sort

  # Checksum over relative path + content, so it is independent of where the
  # app is checked out.
  digest = Digest::SHA256.new
  emitted.each do |file|
    digest << Pathname.new(file).relative_path_from(APP_ROOT).to_s
    digest << File.binread(file)
  end

  manifest = {
    'generator_version' => GENERATOR_VERSION,
    'seed' => SEED,
    'scale' => scale,
    'families' => families.size,
    'hubs' => hubs.size,
    'file_count' => emitted.size,
    'tree_sha256' => digest.hexdigest,
    'rng_check' => rng.rand(1_000_000)
  }
  write 'tmp/generated_manifest.json', "#{JSON.pretty_generate(manifest)}\n"

  manifest
end

def verify!
  scale = scale_from_env
  first = generate!(scale)
  second = generate!(scale)

  if first['tree_sha256'] == second['tree_sha256']
    puts "DETERMINISTIC  scale=#{scale} files=#{first['file_count']} sha=#{first['tree_sha256'][0, 16]}"
    exit 0
  end

  warn 'NON-DETERMINISTIC — two runs at the same scale produced different trees'
  warn "  #{first['tree_sha256']}"
  warn "  #{second['tree_sha256']}"
  exit 1
end

case ARGV.first
when '--clean'  then clean!
when '--verify' then verify!
else
  scale = scale_from_env
  manifest = generate!(scale)
  puts "generated scale=#{scale} (#{manifest['families']} families, #{manifest['file_count']} files)"
  puts "tree sha256: #{manifest['tree_sha256']}"
  puts "manifest:    tmp/generated_manifest.json"
end
