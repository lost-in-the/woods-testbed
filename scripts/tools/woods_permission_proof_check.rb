# frozen_string_literal: true

# Run from the HOST (CI variants job), never in the container:
#
#   ruby scripts/tools/woods_permission_proof_check.rb apps/rails-8.0/tmp/woods
#
# Host-side half of the woods#252 cross-UID permission proof. The container
# half (scripts/woods_extract_only_boot_smoke.rb) writes watch_status.json —
# the one artifact widened to 0644 — into the bind-mounted index dir as the
# container UID, plus permission_proof.json describing what it wrote. This
# script then plays the documented consumer: a host-side worktree hook reading
# the status file through the mount as a DIFFERENT UID, while every payload
# artifact stays locked to its owner.
#
# spec/watch/status_spec.rb can only pin modes in-process; this is the
# cross-boundary consumer that justifies the widening, exercised for real.
#
# CI ordering matters: this must run before the step that chowns the extracted
# index to the runner user, which would erase the UID boundary being proven.

require 'json'

INDEX_DIR = ARGV[0] or abort 'usage: ruby scripts/tools/woods_permission_proof_check.rb <index-dir>'
PROOF_PATH = File.join(INDEX_DIR, 'permission_proof.json')

passed = 0
failed = 0

def check(name)
  yield
  puts "  PASS  #{name}"
  :pass
rescue StandardError => e
  puts "  FAIL  #{name}: #{e.class}: #{e.message}"
  :fail
end

def skip(name, reason)
  puts "  SKIP  #{name}: #{reason}"
end

def outcome(results)
  results.each { |r| return :fail if r == :fail }
  :pass
end

proof = {}

section = outcome([
  check('permission_proof.json exists and parses') do
    raise "no proof at #{PROOF_PATH}: container smoke script did not run to completion" unless File.file?(PROOF_PATH)

    proof.merge!(JSON.parse(File.read(PROOF_PATH, encoding: 'UTF-8')))
  end,

  check('reader is genuinely a different UID than the container writer') do
    raise 'proof missing container_uid' unless proof['container_uid']
    raise "reader uid #{Process.uid} == container uid #{proof['container_uid']}: " \
          'same-UID read proves nothing; run the checker on the host against the mounted index' if Process.uid == proof['container_uid']
  end
])

watch = proof['watch_status']
status_results =
  if proof['status_contract'] == '0644' && watch
    status_path = File.join(INDEX_DIR, watch['path'])

    [
      # The headline: the exact consumer the 0644 widening exists for. A host
      # UID with no write access to the container's tree reads the status
      # file through the bind mount.
      check('host UID reads the container-written watch_status.json through the mount') do
        record = JSON.parse(File.read(status_path, encoding: 'UTF-8'))
        raise "status state #{record['state'].inspect}, expected running" unless record['state'] == 'running'
      end,

      check('watch_status.json is 0644 and owned by the container UID') do
        stat = File.stat(status_path)
        raise "mode #{format '%o', stat.mode & 0o777}, expected 644" unless stat.mode & 0o777 == 0o644
        raise "owner uid #{stat.uid}, expected #{proof['container_uid']}" unless stat.uid == proof['container_uid']
      end
    ]
  else
    skip('watch_status.json cross-UID read', 'container gem predates AtomicFile mode: (woods#252 not merged)')
    []
  end
section = :fail if section == :fail || outcome(status_results) == :fail

sample_results =
  if proof['extracted']
    proof['payload_samples'].map do |sample|
      path = File.join(INDEX_DIR, sample['path'])

      # Two halves, both needed: the mode is exactly 0600, and a read attempt
      # as this (non-owner) UID actually fails. A mode assertion alone would
      # not catch a kernel/mount that ignores permission bits.
      check("payload #{sample['path']} stays 0600 and refuses the host UID") do
        stat = File.stat(path)
        raise "mode #{format '%o', stat.mode & 0o777}, expected 600" unless stat.mode & 0o777 == 0o600
        raise "owner uid #{stat.uid}, expected #{proof['container_uid']}" unless stat.uid == proof['container_uid']

        begin
          File.read(path, encoding: 'UTF-8')
          raise "readable across the unintended boundary: host UID #{Process.uid} read a 0600 file"
        rescue Errno::EACCES, Errno::EPERM
          # expected: the boundary held
        end
      end
    end
  else
    skip('payload 0600 + unreadable checks', 'container had no extracted index (proof says extracted: false)')
    []
  end
section = :fail if outcome(sample_results) == :fail

puts
puts section == :pass ? 'permission proof: PASS' : 'permission proof: FAIL'
exit(section == :pass ? 0 : 1)
