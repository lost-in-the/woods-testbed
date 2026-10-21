# frozen_string_literal: true

# Exercise the smoke's capability branches without Rails, a server or an index.
require 'open3'
require 'rbconfig'

fixture = <<~'RUBY'
  scenario = ARGV.pop
  module Rails
    def self.application; end
    def self.version; 'synthetic'; end
  end
  MailingListMailer = Class.new
  module WoodsMap
    Engine = Class.new
    VERSION = 'synthetic'
    def self.configuration
      Struct.new(:index_path).new('/synthetic/index')
    end
    class Repository
      def self.open(_path)
        yield new
      end
      def unit(_identifier, type:)
        { 'metadata' => self.class.metadata }
      end
      class << self
        attr_accessor :metadata
      end
    end
    class Passage
      def initialize(*); end
    end
  end
  assigns = %w[@user @post]
  assigns = ['@post'] if scenario == 'missing_assignment'
  assigns += ['@preferences'] if scenario == 'invented_assignment'
  file = 'app/mailers/mailing_list_mailer.rb'
  facts = { 'new_post' => {
    'file' => file, 'line' => 5,
    'assigns' => assigns.map { |ivar| { 'ivar' => ivar, 'method' => 'new_post', 'file' => file, 'line' => 6 } },
    'renders' => [{ 'template' => 'mailing_list_mailer/new_post', 'mail' => true,
                    'method' => 'new_post', 'file' => file, 'line' => 8 }],
    'params' => [], 'redirects' => [], 'formats' => []
  } }
  facts['new_post'].delete('renders') if %w[incomplete incomplete_known_empty].include?(scenario)
  unavailable = %w[legacy legacy_wrong_ui unavailable unavailable_wrong_ui].include?(scenario)
  WoodsMap::Repository.metadata = unavailable || scenario == 'missing_facts' ? {} : { 'action_facts' => facts }
  unless scenario.start_with?('legacy')
    ivars = case scenario
            when 'unavailable', 'unavailable_wrong_ui', 'complete_facts_nil_flags', 'incomplete' then nil
            when 'known_empty', 'incomplete_known_empty' then []
            when 'false_flag' then %w[@preferences @post]
            when 'false_user_flag' then %w[@preferences @user]
            when 'duplicate_flag' then %w[@preferences @preferences]
            else ['@preferences']
            end
    flags = ivars&.map { |ivar| Struct.new(:ivar).new(ivar) }
    WoodsMap::Passage.define_method(:flags) { flags }
  end
  base = '@preferences unassigned-ivar-read '
  unavailable_ui = %w[legacy legacy_with_facts unavailable available_wrong_ui complete_facts_nil_flags
                      incomplete incomplete_known_empty].include?(scenario)
  body = base + if unavailable_ui
                  'No flag can be raised yet.'
                elsif scenario == 'missing_flag_ui'
                  'no matching flag markup'
                else
                  '<span class="iv bad">@preferences</span>, no recorded assignment'
                end
  module Rack
    class MockRequest
      def initialize(_application); end
      def get(path, _headers)
        body = if path.include?('/passage')
                 self.class.passage_body
               else
                 'gen 1 class="cv codeview" href="/woods/units/model/User" ' \
                   'Blast radius set_slug notify_subscribers'
               end
        Struct.new(:status, :body).new(200, body)
      end
      class << self
        attr_accessor :passage_body
      end
    end
  end
  Rack::MockRequest.passage_body = body
  load ARGV.fetch(0)
RUBY

smoke = File.expand_path('../woods_map_smoke.rb', __dir__)
scenarios = {
  'legacy' => true, 'legacy_with_facts' => true, 'unavailable' => true, 'available' => true, 'incomplete' => true,
  'complete_facts_nil_flags' => false, 'incomplete_known_empty' => false,
  'known_empty' => false, 'false_flag' => false, 'false_user_flag' => false, 'duplicate_flag' => false,
  'missing_assignment' => false,
  'invented_assignment' => false, 'missing_facts' => false, 'missing_flag_ui' => false,
  'available_wrong_ui' => false, 'unavailable_wrong_ui' => false, 'legacy_wrong_ui' => false
}
scenarios.each do |name, expected|
  stdout, stderr, status = Open3.capture3({ 'WOODS_MAP_TOKEN' => nil }, RbConfig.ruby, '-e', fixture, smoke, name)
  raise "#{name}: expected success=#{expected}, got #{status.exitstatus}\n#{stdout}\n#{stderr}" unless status.success? == expected

  puts "PASS #{name} #{expected ? 'accepted' : 'rejected'}"
end
puts "#{scenarios.size}/#{scenarios.size} capability cases passed"
