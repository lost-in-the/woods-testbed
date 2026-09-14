# frozen_string_literal: true
# Read-only outside a rolled-back edit probe. Run after seeding the smoke profile.
require 'json'
abort 'Canopy fixture required' unless Rails.root.join('functional_contract.yml').file?
manifest = JSON.parse(Testbed::Dataset.manifest_path.read)
abort 'This check requires TESTBED_DATA_PROFILE=smoke' unless manifest['profile'] == 'smoke'
before = Testbed::Dataset.fingerprint
Testbed::Dataset.new.run(profile: 'smoke')
raise 'Seed rerun changed data' unless Testbed::Dataset.fingerprint == before
ActiveRecord::Base.transaction do
  subscriber = Subscriber.find_by!(email: 'reader0@example.test')
  subscriber.update!(name: 'An interactive edit to preserve')
  Testbed::Dataset.new.run(profile: 'smoke')
  raise 'Seed erased an interactive edit' unless subscriber.reload.name == 'An interactive edit to preserve'
  raise ActiveRecord::Rollback
end
raise 'Probe did not roll back' unless Testbed::Dataset.fingerprint == before
raise 'Missing seed tables' unless (Testbed::Dataset::TABLES - ActiveRecord::Base.connection.tables).empty?
raise 'Missing populated model family' unless manifest.fetch('counts').values.all?(&:positive?)
raise 'Unbounded smoke fixture' unless manifest.fetch('counts').values.sum.between?(900, 1100)
puts 'PASS seed rerun, edit preservation, rollback, table coverage, and smoke size'
