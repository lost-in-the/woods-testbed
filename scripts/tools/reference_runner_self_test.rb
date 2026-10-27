# frozen_string_literal: true

# Refusal paths only: never start Docker or load a producer.
require 'open3'
require 'rbconfig'
require 'tmpdir'

runner = File.expand_path('../../bin/woods_reference_acceptance.rb', __dir__)
revision = '0' * 40
flags = [[], ['--verified-constant-spans'], ['--verified-constant-method-spans']]

def refused!(runner, args, message)
  output, error, status = Open3.capture3(RbConfig.ruby, runner, *args)
  raise "expected refusal #{message.inspect}: #{output}#{error}" unless !status.success? && error.include?(message)

  puts "PASS #{args.grep(/\A--/).join(' ')} refuses #{message}"
end

output, error, status = Open3.capture3(RbConfig.ruby, runner, '--help')
raise "missing explicit method mode: #{error}" unless status.success? && output.include?('--verified-constant-method-spans')

puts 'PASS CLI advertises the explicit method contract'
Dir.mktmpdir('reference-runner-self-test') do |root|
  artifact = File.join(root, 'synthetic.gem')
  File.binwrite(artifact, 'synthetic public refusal fixture, not a package')
  report = File.join(root, 'must-not-exist')
  common = ['--gem', artifact, '--sha256', '0' * 64, '--revision', revision,
            '--docker', File.join(root, 'must-not-execute'), '--report-dir', report]
  flags.each do |mode|
    refused!(runner, common + mode, 'artifact SHA256 mismatch')
  end
  refused!(runner, common + ['--failure-only', '--verified-constant-spans'],
           '--failure-only cannot qualify verified constant spans')
  refused!(runner, common + ['--failure-only', '--verified-constant-method-spans'],
           '--failure-only cannot qualify verified constant method spans')
  refused!(runner, common + ['--verified-constant-spans', '--verified-constant-method-spans'],
           'choose only one verified span contract')
  refused!(runner, common + ['--failure-only', '--discovery-regressions'],
           '--failure-only cannot run discovery regressions')
  refused!(runner, common + ['--failure-only', '--baseline-woods', root],
           '--failure-only cannot measure a baseline')
  raise 'refusal created a report directory' if File.exist?(report)

  puts 'PASS all refusals precede report creation and Docker execution'
end
