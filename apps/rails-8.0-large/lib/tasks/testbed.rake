namespace :testbed do
  desc 'Create the deterministic Canopy dataset (preserves existing edits)'
  task seed: :environment do
    Testbed::Dataset.new.run
  end
  desc 'Delete the local Canopy database and rebuild it; requires CONFIRM=reset-canopy'
  task :reset do
    abort 'Set CONFIRM=reset-canopy to erase this variant database' unless ENV['CONFIRM'] == 'reset-canopy'
    abort 'Reset is development/test only' unless %w[development test].include?(ENV.fetch('RAILS_ENV', 'development'))
    Rake::Task['db:drop'].invoke
    Rake::Task['db:create'].invoke
    Rake::Task['db:migrate'].invoke
    FileUtils.rm_f(Testbed::Dataset.manifest_path)
    Rake::Task['testbed:seed'].invoke
  end
  desc 'Run due publishing/renewal jobs and finish queued local deliveries'
  task drain: :environment do
    PublishDueArticlesJob.perform_now
    RenewSubscriptionsJob.perform_now
    Newsletter::Delivery.where(state: 'queued').find_each { |d| Newsletter::DeliverJob.perform_now(d.id) }
    WebhookDelivery.where.not(state: 'delivered').find_each { |d| WebhookDeliveryJob.perform_now(d.id) }
  end
  desc 'Print deterministic report answers at the dataset reference time'
  task report: :environment do
    at = Time.zone.parse(ENV.fetch('TESTBED_REFERENCE_TIME', '2026-09-14T12:00:00Z'))
    Organization.order(:slug).each do |organization|
      report = EditorialReport.new(organization, at: at)
      puts({ organization: organization.slug, review_backlog: report.review_backlog.count, overdue_cents: report.overdue_cents, newsletter: report.newsletter_outcomes }.to_json)
    end
  end
end
