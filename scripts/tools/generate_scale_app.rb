# frozen_string_literal: true

# Run with:  ruby script/shared/tools/generate_scale_app.rb   (no Rails needed)
#
# Expands apps/rails-8.0-large into a Packwerk-shaped application of realistic
# size for measuring Woods extraction and Woods Map at scale: packages under
# packs/, each with namespaced models on their own tables (associations both
# ways, callbacks, scopes, validations and the pack's concerns inlined),
# RESTful controllers with filters and one 40-action admin controller per pack,
# a view per action, jobs (some with retry policies) and mailers with their
# templates. generate_large_app.rb multiplies one simple family shape; this one
# varies shape, which is what a code explorer's pages are sensitive to
# (the largest model, the widest controller, the hubs of the graph).
#
# Deterministic: a seeded PRNG, sorted iteration, no timestamps in the output;
# tmp/scale_manifest.json records the counts and a checksum of the tree.
# Everything it writes lives under packs/, app/views/<pack>/, db/scale/ and
# config/routes_scale.rb, all gitignored and wired by config/application.rb.
#
# Usage (from the app root; G=script/shared/tools/generate_scale_app.rb):
#   SCALE=large ruby $G      # 1,500 models, 400 controllers, 300 jobs and mailers (~10,000 units)
#   SCALE=medium ruby $G     # ~5,000 units
#   SCALE_MODELS=.. SCALE_CONTROLLERS=.. SCALE_JOBS=.. SCALE_MAILERS=.. SCALE_PACKS=.. ruby $G
#   ruby $G --clean
#
# Then: bin/rails db:migrate && bin/rails woods:extract. A throwaway history of
# a few thousand commits: ruby $G --history 3000 (refuses an app that already
# has .git).

require 'digest'
require 'fileutils'
require 'json'
require 'pathname'

GENERATOR_VERSION = 1
SEED = 20_261_024
ROOT = Pathname.new(ENV['WOODS_GEN_APP_ROOT'] || Dir.pwd)

PRESETS = {
  'small' => { models: 60, controllers: 24, jobs: 12, mailers: 6, packs: 3 },
  'medium' => { models: 600, controllers: 160, jobs: 80, mailers: 40, packs: 8 },
  'large' => { models: 1500, controllers: 400, jobs: 200, mailers: 100, packs: 12 }
}.freeze

PACKS = %w[catalog fulfilment identity insights inventory logistics marketplace messaging payments pricing reviews
           scheduling procurement warehousing ledger].freeze
NOUNS = %w[widget address adjustment allocation approval asset attachment batch booking bundle campaign carrier
           channel charge checkpoint claim contract coupon credential cycle delivery deposit device discount dispatch
           document entry estimate event exception feed forecast grant handoff hold import incident item journal label
           lease limit listing lot manifest match measure milestone note offer gadget package parcel partner payout
           period permit plan policy position quota quote rate thing reconciliation record refund region release
           request reservation return review route rule schedule segment settlement shipment slot snapshot source
           statement subscription supplier survey tariff task tender ticket transfer trip unit variant vendor visit
           voucher wave window zone].freeze
# Views live where Rails looks for a namespaced controller's templates:
# app/views/<pack>/<controller>/. The pack names avoid Canopy's own namespaces.
PATHS = (%w[packs db/scale config/routes_scale.rb tmp/scale_manifest.json] + PACKS.map { |p| "app/views/#{p}" }).freeze
CONCERNS = %w[Auditable Archivable Sluggable Taggable Versioned Searchable Expirable Approvable Notifiable
              Geocoded].freeze

def config
  base = PRESETS.fetch(ENV.fetch('SCALE', 'large'))
  { models: Integer(ENV.fetch('SCALE_MODELS', base[:models])),
    controllers: Integer(ENV.fetch('SCALE_CONTROLLERS', base[:controllers])),
    jobs: Integer(ENV.fetch('SCALE_JOBS', base[:jobs])), mailers: Integer(ENV.fetch('SCALE_MAILERS', base[:mailers])),
    packs: [Integer(ENV.fetch('SCALE_PACKS', base[:packs])), PACKS.size].min }
end

def camel(snake) = snake.split('_').map(&:capitalize).join

def write(path, body)
  file = ROOT.join(path)
  FileUtils.mkdir_p(file.dirname)
  File.write(file, body)
end

def clean!
  PATHS.each { |path| FileUtils.rm_rf(ROOT.join(path)) }
end

# Model records for one pack: name, table, belongs_to targets.
def plan_models(pack, count, rng)
  (0...count).map do |i|
    noun = NOUNS[i % NOUNS.size]
    noun = "#{noun}#{(i / NOUNS.size) + 1}" if i >= NOUNS.size
    targets = i.zero? ? [] : Array.new([1, rng.rand(1..3)].max) { i < 4 ? 0 : (rng.rand < 0.4 ? 0 : rng.rand(i)) }.uniq
    { pack: pack, index: i, snake: noun, class: "#{camel(pack)}::#{camel(noun)}", table: "#{pack}_#{noun}s",
      belongs: targets, concerns: i.zero? ? CONCERNS.dup : CONCERNS.sample(rng.rand(1..3), random: rng).sort }
  end
end

def model_source(model, models, jobs)
  belongs = model[:belongs].map do |t|
    target = models[t]
    "  belongs_to :#{target[:snake]}, class_name: \"#{target[:class]}\", optional: true"
  end
  has_many = models.select { |m| m[:belongs].include?(model[:index]) }.map do |m|
    "  has_many :#{m[:snake]}s, class_name: \"#{m[:class]}\", dependent: :nullify"
  end
  job = jobs[model[:index] % jobs.size] if jobs.any?
  <<~RUBY
    module #{camel(model[:pack])}
      class #{camel(model[:snake])} < ApplicationRecord
        self.table_name = "#{model[:table]}"
    #{model[:concerns].map { |c| "    include #{camel(model[:pack])}::#{c}" }.join("\n")}

    #{(belongs + has_many).map { |line| "  #{line}" }.join("\n")}

        validates :name, presence: true, length: { maximum: 120 }
        validates :code, uniqueness: true, allow_nil: true

        before_validation :normalize_name
        before_save :stamp_revision, if: :name_changed?
        #{job ? "after_create_commit :enqueue_refresh" : ''}

        scope :active, -> { where(active: true) }
        scope :recent, -> { order(created_at: :desc) }

        def display_name
          [code, name].compact.join(" · ")
        end

        def overdue?
          due_on.present? && due_on < Date.current
        end

        private

        def normalize_name
          self.name = name.to_s.squish
        end

        def stamp_revision
          self.revision = revision.to_i + 1
        end
    #{if job
        <<~JOB.chomp

              def enqueue_refresh
                #{job[:class]}.perform_later(id)
              end
        JOB
      end}
      end
    end
  RUBY
end

def concern_source(pack, name)
  snake = name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
  <<~RUBY
    module #{camel(pack)}
      module #{name}
        extend ActiveSupport::Concern

        included do
          before_save :prepare_#{snake}
          scope :#{snake}_ready, -> { where.not(updated_at: nil) }
        end

        def #{snake}_summary
          "#{name}: \#{id}"
        end

        private

        def prepare_#{snake}
          self.updated_at ||= Time.current
        end
      end
    end
  RUBY
end

REST = %w[index show new create edit update destroy].freeze

def controller_source(pack, ctrl)
  model = ctrl[:model]
  extra = ctrl[:extra].map do |action|
    "    def #{action}\n      @records = #{model[:class]}.#{action.end_with?('_due') ? 'recent' : 'active'}.limit(50)\n    end\n"
  end
  <<~RUBY
    module #{camel(pack)}
      class #{ctrl[:class]} < ApplicationController
        before_action :set_record, only: %i[show edit update destroy]
        before_action :require_editor, except: %i[index show]

        def index
          @records = #{model[:class]}.recent.limit(50)
        end

        def show; end

        def new
          @record = #{model[:class]}.new
        end

        def create
          @record = #{model[:class]}.new(record_params)
          if @record.save
            redirect_to #{pack}_#{ctrl[:route]}_path(@record), status: :see_other
          else
            render :new, status: :unprocessable_entity
          end
        end

        def edit; end

        def update
          if @record.update(record_params)
            redirect_to #{pack}_#{ctrl[:route]}_path(@record), status: :see_other
          else
            render :edit, status: :unprocessable_entity
          end
        end

        def destroy
          @record.destroy
          redirect_to #{pack}_#{ctrl[:route]}s_path, status: :see_other
        end

    #{extra.join("\n")}
        private

        def set_record
          @record = #{model[:class]}.find(params[:id])
        end

        def require_editor
          head :forbidden unless params[:editor].present?
        end

        def record_params
          params.require(:#{model[:snake]}).permit(:name, :code, :active, :due_on)
        end
      end
    end
  RUBY
end

def view_source(ctrl, action)
  case action
  when 'index', /_due\z/, /_report\z/
    "<h1>#{ctrl[:class]} #{action}</h1>\n<ul>\n  <% @records.each do |record| %>\n    <li><%= link_to record.display_name, " \
      "#{ctrl[:pack]}_#{ctrl[:route]}_path(record) %></li>\n  <% end %>\n</ul>\n"
  when 'show' then "<h1><%= @record.display_name %></h1>\n<%= link_to \"Edit\", edit_#{ctrl[:pack]}_#{ctrl[:route]}_path(@record) %>\n"
  when 'new', 'edit' then "<h1>#{action.capitalize}</h1>\n<%= form_with model: @record, url: #{ctrl[:pack]}_#{ctrl[:route]}s_path do |f| %>\n  <%= f.text_field :name %>\n<% end %>\n"
  end
end

def plan(cfg)
  rng = Random.new(SEED)
  packs = PACKS.first(cfg[:packs])
  share = ->(total, i) { (total / packs.size) + (i < total % packs.size ? 1 : 0) }
  packs.each_with_index.map do |pack, p|
    jobs = (0...share.call(cfg[:jobs], p)).map { |j| { class: "#{camel(pack)}::Refresh#{j}Job", snake: "refresh#{j}_job", index: j } }
    models = plan_models(pack, share.call(cfg[:models], p), rng)
    controllers = (0...share.call(cfg[:controllers], p)).map do |c|
      model = models[c % models.size]
      route = c < models.size ? model[:snake] : "#{model[:snake]}_#{c}"
      extra = c.zero? ? (1..33).map { |n| n.odd? ? "batch#{n}_report" : "batch#{n}_due" } : []
      { pack: pack, class: "#{camel(route)}sController", snake: "#{route}s", route: route, model: model, extra: extra,
        admin: c.zero? }
    end
    mailers = (0...share.call(cfg[:mailers], p)).map { |m| { class: "#{camel(pack)}::Notice#{m}Mailer", snake: "notice#{m}_mailer" } }
    deps = packs.reject { |other| other == pack }.sample(rng.rand(1..2), random: rng).sort
    { name: pack, models: models, controllers: controllers, jobs: jobs, mailers: mailers, deps: deps }
  end
end

def generate!(cfg)
  clean!
  packs = plan(cfg)
  route_blocks = []
  packs.each do |pack|
    name = pack[:name]
    base = "packs/#{name}"
    write "#{base}/package.yml", "enforce_dependencies: true\nenforce_privacy: false\n" \
                                 "dependencies:\n#{pack[:deps].map { |d| "  - packs/#{d}\n" }.join}"
    CONCERNS.each { |c| write "#{base}/app/models/#{name}/#{c.gsub(/([a-z])([A-Z])/, '\1_\2').downcase}.rb", concern_source(name, c) }
    pack[:models].each { |m| write "#{base}/app/models/#{name}/#{m[:snake]}.rb", model_source(m, pack[:models], pack[:jobs]) }
    pack[:jobs].each do |job|
      model = pack[:models][job[:index] % pack[:models].size]
      retry_line = job[:index].even? ? "\n    retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3" : ''
      write "#{base}/app/jobs/#{name}/#{job[:snake]}.rb", <<~RUBY
        module #{camel(name)}
          class Refresh#{job[:index]}Job < ApplicationJob
            queue_as :#{name}#{retry_line}

            def perform(record_id)
              record = #{model[:class]}.find(record_id)
              record.touch
            end
          end
        end
      RUBY
    end
    pack[:mailers].each do |mailer|
      write "#{base}/app/mailers/#{name}/#{mailer[:snake]}.rb", <<~RUBY
        module #{camel(name)}
          class #{mailer[:class].split('::').last} < ApplicationMailer
            def opened(record)
              @record = record
              mail(to: "ops@example.test", subject: "Opened \#{record.id}")
            end

            def closed(record)
              @record = record
              mail(to: "ops@example.test", subject: "Closed \#{record.id}")
            end
          end
        end
      RUBY
      %w[opened closed].each do |action|
        write "app/views/#{name}/#{mailer[:snake]}/#{action}.html.erb", "<p><%= @record.display_name %> #{action}</p>\n"
        write "app/views/#{name}/#{mailer[:snake]}/#{action}.text.erb", "<%= @record.display_name %> #{action}\n"
      end
    end
    pack_routes = []
    pack[:controllers].each do |ctrl|
      write "#{base}/app/controllers/#{name}/#{ctrl[:snake]}_controller.rb", controller_source(name, ctrl)
      (REST - %w[create update destroy] + ctrl[:extra]).each do |action|
        write "app/views/#{name}/#{ctrl[:snake]}/#{action}.html.erb", view_source(ctrl, action)
      end
      extra = ctrl[:extra].map { |a| "        get :#{a}, on: :collection" }
      pack_routes << "    resources :#{ctrl[:route]}s, controller: \"#{ctrl[:snake]}\"#{extra.any? ? " do\n#{extra.join("\n")}\n      end" : ''}"
    end
    route_blocks << "  namespace :#{name}, path: \"scale/#{name}\" do\n#{pack_routes.join("\n")}\n  end"
    columns = "      t.string :name, null: false\n      t.string :code\n      t.boolean :active, default: true, null: false\n" \
              "      t.date :due_on\n      t.integer :revision, default: 0, null: false\n      t.decimal :amount, precision: 12, scale: 2\n"
    tables = pack[:models].map do |m|
      fks = m[:belongs].map { |t| "      t.references :#{pack[:models][t][:snake]}, foreign_key: { to_table: :#{pack[:models][t][:table]} }\n" }.join
      "    create_table :#{m[:table]} do |t|\n#{columns}#{fks}      t.timestamps\n    end\n"
    end
    stamp = 20_261_001_000_000 + PACKS.index(name)
    write "db/scale/migrate/#{stamp}_create_#{name}_tables.rb", <<~RUBY
      class Create#{camel(name)}Tables < ActiveRecord::Migration[8.0]
        def change
      #{tables.join("\n")}  end
      end
    RUBY
  end
  write 'config/routes_scale.rb', "# Generated by scripts/tools/generate_scale_app.rb.\nRails.application.routes.draw do\n#{route_blocks.join("\n")}\nend\n"
  manifest(cfg, packs)
end

def manifest(cfg, packs)
  files = PATHS.flat_map { |p| Dir[ROOT.join(p).to_s, ROOT.join(p, '**/*').to_s] }.select { |f| File.file?(f) }.uniq.sort
  digest = Digest::SHA256.new
  files.each { |f| digest << Pathname.new(f).relative_path_from(ROOT).to_s << File.binread(f) }
  data = { 'generator_version' => GENERATOR_VERSION, 'seed' => SEED, 'config' => cfg, 'packs' => packs.size,
           'models' => packs.sum { |p| p[:models].size }, 'controllers' => packs.sum { |p| p[:controllers].size },
           'jobs' => packs.sum { |p| p[:jobs].size }, 'mailers' => packs.sum { |p| p[:mailers].size },
           'file_count' => files.size, 'tree_sha256' => digest.hexdigest }
  write 'tmp/scale_manifest.json', "#{JSON.pretty_generate(data)}\n"
  data
end

# A throwaway history: one import commit, then `count` commits by eight
# authors over the last 330 days, each touching one to three generated files
# (or app files, on an app the generator has not expanded).
def history!(count)
  abort "refusing: #{ROOT} already has .git" if ROOT.join('.git').exist?
  files = Dir[ROOT.join('packs/**/*.rb').to_s].sort
  files = Dir[ROOT.join('app/**/*.rb').to_s].sort if files.empty? # an ungenerated app gets history on its own code
  abort "no Ruby files under #{ROOT}" if files.empty?
  rng = Random.new(SEED + 1)
  authors = ['Ada Lovelace', 'Grace Hopper', 'Linus Pauling', 'Katherine Johnson', 'Alan Turing', 'Barbara Liskov',
             'Edsger Dijkstra', 'Margaret Hamilton']
  now = Time.now.to_i
  git = ->(*args, env: {}) { system(env, 'git', '-C', ROOT.to_s, *args, out: File::NULL) || abort("git #{args.first} failed") }
  git.call('init', '-q', '-b', 'main')
  git.call('add', '-A')
  # The generated tree is gitignored in the testbed; a throwaway history tracks it.
  generated = PATHS.reject { |p| p.start_with?('tmp/') }.select { |p| ROOT.join(p).exist? }
  git.call('add', '-f', '--', *generated) if generated.any?
  start = now - (331 * 86_400)
  git.call('commit', '-qm', 'Import the application', env: identity('Ada Lovelace', start))
  count.times do |n|
    author = authors[rng.rand(authors.size)]
    touched = files.sample(rng.rand(1..3), random: rng)
    touched.each { |f| File.open(f, 'a') { |io| io.puts "# revision #{n}" } }
    git.call('add', '-f', '--', *touched)
    git.call('commit', '-qm', "Revise #{File.basename(touched.first, '.rb')} (#{n})",
             env: identity(author, start + ((n + 1) * (330 * 86_400) / count)))
  end
end

def identity(name, time)
  email = "#{name.downcase.tr(' ', '.')}@example.test"
  date = Time.at(time).utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  { 'GIT_AUTHOR_NAME' => name, 'GIT_AUTHOR_EMAIL' => email, 'GIT_COMMITTER_NAME' => name,
    'GIT_COMMITTER_EMAIL' => email, 'GIT_AUTHOR_DATE' => date, 'GIT_COMMITTER_DATE' => date }
end

if ARGV.include?('--clean')
  clean!
elsif (i = ARGV.index('--history'))
  history!(Integer(ARGV[i + 1] || 3000))
else
  puts JSON.pretty_generate(generate!(config))
end
