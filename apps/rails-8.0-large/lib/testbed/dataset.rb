require 'json'
require 'digest'
require 'active_support/testing/time_helpers'

module Testbed
  class Dataset
    include ActiveSupport::Testing::TimeHelpers
    VERSION = 2
    PROFILES = {
      'smoke' => { organizations: 2, publications: 3, authors: 12, articles: 30, subscribers: 60, events: 120 },
      'demo' => { organizations: 5, publications: 12, authors: 80, articles: 600, subscribers: 2_000, events: 25_000 },
      'stress' => { organizations: 25, publications: 75, authors: 500, articles: 10_000, subscribers: 25_000, events: 200_000 }
    }.freeze
    TABLES = %w[organizations publications memberships authors articles article_revisions review_assignments review_decisions comments tags article_tags collections collection_articles subscribers billing_plans billing_subscriptions billing_subscription_changes billing_invoices billing_line_items billing_payments billing_refunds newsletter_campaigns newsletter_deliveries engagement_events support_tickets support_ticket_messages activity_events webhook_endpoints webhook_deliveries payouts_payees payouts_individual_profiles payouts_agency_profiles payouts_representations payouts_rate_cards payouts_earnings payouts_payout_runs payouts_statements payouts_transfers syndication_partners syndication_licenses syndication_usage_reports].freeze
    TOPICS = ['Restoring the river trail', 'The community seed library', 'Night walks and migrating birds', 'A field guide to urban trees', 'Repairing the old footbridge', 'Local growers after the storm'].freeze

    def self.manifest_path = Rails.root.join(ENV.fetch("TESTBED_MANIFEST_PATH", "tmp/canopy_dataset_#{Rails.env}.json"))
    def self.fingerprint
      connection = ActiveRecord::Base.connection
      digest = Digest::SHA256.new
      TABLES.each do |table|
        # Stable row order and bounded batches, including user edits in the digest.
        offset = 0
        loop do
          rows = connection.select_all("SELECT * FROM #{connection.quote_table_name(table)} ORDER BY id LIMIT 1000 OFFSET #{offset}").to_a
          break if rows.empty?
          digest.update(JSON.generate([table, rows]))
          offset += rows.length
        end
      end
      digest.hexdigest
    end

    def run(profile: ENV.fetch('TESTBED_DATA_PROFILE', 'demo'))
      @size = PROFILES.fetch(profile) { raise ArgumentError, 'Choose smoke, demo, or stress' }
      if self.class.manifest_path.exist?
        manifest = JSON.parse(self.class.manifest_path.read)
        if Author.exists?(email: 'editor0@example.test')
          changed = self.class.fingerprint != manifest['fingerprint']
          puts "Canopy dataset already exists (#{manifest['profile']}); #{changed ? 'edits detected and preserved' : 'unchanged'}. Seed skipped. Use testbed:reset for a fresh dataset."
          return manifest
        end
      end
      raise 'Seed identity exists without a matching manifest; use testbed:reset for a fresh fixture' if Author.exists?(email: 'editor0@example.test')
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @at = Time.zone.parse(ENV.fetch('TESTBED_REFERENCE_TIME', '2026-09-14T12:00:00Z'))
      @rng = Random.new(20260914)
      previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      travel_to(@at) do
        ActiveRecord::Base.transaction do
          build_organizations
          build_editorial
          build_commerce
          build_audience
          build_support
          build_syndication
          build_payouts
        end
      end
      manifest = { version: VERSION, profile: profile, reference_time: @at.iso8601, seed: 20260914,
        counts: TABLES.to_h { |table| [table, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}").to_i] },
        scenarios: @scenarios, fingerprint: self.class.fingerprint,
        seed_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3) }
      self.class.manifest_path.dirname.mkpath
      self.class.manifest_path.write(JSON.pretty_generate(manifest) + "\n")
      puts "Canopy #{profile}: #{manifest[:counts].values.sum} rows in #{manifest[:seed_seconds]}s"
      manifest
    ensure
      ActiveJob::Base.queue_adapter = previous_adapter if previous_adapter
    end

    private
    def build_organizations
      @organizations = Array.new(@size[:organizations]) do |i|
        Organization.find_or_create_by!(slug: i.zero? ? 'canopy' : "canopy-#{i}") { |o| o.name = "Canopy Press #{i + 1}" }
      end
      @authors = Array.new(@size[:authors]) do |i|
        author = Author.create!(name: i < @organizations.size ? "Editor #{i + 1}" : "Writer #{i + 1}", email: "#{i < @organizations.size ? 'editor' : 'writer'}#{i}@example.test")
        author.memberships.create!(organization: @organizations[i % @organizations.size], role: i < @organizations.size ? 'editor' : 'author')
        author
      end
      @publications = Array.new(@size[:publications]) do |i|
        Publication.find_or_create_by!(slug: i.zero? ? 'field-notes' : "publication-#{i}") do |p|
          p.organization = @organizations[i % @organizations.size]
          p.name = ["Field Notes", "River Journal", "Neighborhood Almanac"][i % 3] + " #{i + 1}"
        end
      end
      @organizations.each { |o| o.webhook_endpoints.create!(url: "https://hooks.example.test/#{o.slug}", secret: "fictional-webhook-secret-#{o.slug}") }
      @tags = %w[conservation community fieldwork accessibility].map { |name| Tag.find_or_create_by!(name: name) }
      @collections = @publications.map { |p| p.collections.create!(name: 'Dispatches from the field') }
      @scenarios = { rejected_then_approved: 'canopy-story-0', scheduled: 'canopy-story-1', review_backlog: 'canopy-story-2', archived_discussion: 'canopy-story-0', overdue_invoice: 'CANOPY-OVERDUE', partial_refund: 'CANOPY-REFUND', exclusive_license: 'canopy-story-3' }
      build_payees
    end

    def editor(organization) = organization.memberships.where(role: 'editor').order(:id).first!.author

    def writers(organization)
      (@writers ||= {})[organization.id] ||= organization.authors.where(memberships: { role: 'author' }).order(:id).to_a
    end

    # Payees and rate cards exist before build_editorial publishes, because the
    # article.published listener accrues each fee as the story goes live.
    def build_payees
      @organizations.each do |organization|
        writers = writers(organization)
        next if writers.empty?
        agency = Payouts::AgencyProfile.create!(name: "#{organization.name} Literary Agency", contact_email: "desk@#{organization.slug}-agency.example.test")
        agency_payee = Payouts::Payee.create!(organization: organization, profile: agency, display_name: agency.name)
        @scenarios[:agency_payee] ||= agency_payee.display_name
        writers.each_with_index do |writer, rank|
          next agency.representations.create!(author: writer) if rank < 2
          method, details = case rank
            when 2 then ['international_bank', { 'account_last_four' => '5512', 'iban_last_four' => '5512', 'swift_code' => 'CNPYGB2L', 'simulate_timeout' => '1' }]
            when 3 then ['wallet', { 'wallet_handle' => "@#{writer.email.split('@').first}" }]
            when 4 then ['bank', { 'account_last_four' => '0000' }]
            else ['bank', { 'account_last_four' => (1000 + writer.id).to_s[-4..] }]
          end
          profile = Payouts::IndividualProfile.create!(author: writer, legal_name: writer.name, tax_id: format('900-%02d-%04d', organization.id % 100, writer.id), bank_details: details)
          Payouts::Payee.create!(organization: organization, profile: profile, display_name: writer.name, payout_method: method, country_code: method == 'international_bank' ? 'GB' : 'US')
        end
      end
      @publications.each_with_index do |publication, i|
        if i % 3 == 2
          publication.rate_cards.create!(basis: :flat, effective_on: @at.to_date.beginning_of_year, terms: { 'flat_cents' => 900 })
        else
          publication.rate_cards.create!(basis: :per_word, effective_on: @at.to_date.beginning_of_year, terms: { 'cents_per_word' => 4, 'minimum_cents' => 1500 })
        end
      end
    end

    def build_editorial
      @articles = Array.new(@size[:articles]) do |i|
        # A busy publication gives fan-in and skew instead of a uniform graph.
        publication = i % 3 == 0 ? @publications.first : @publications[i % @publications.size]
        # Rotate through the organization's writers so payouts have several payees.
        writers = writers(publication.organization)
        author = writers.any? ? writers[i % writers.size] : editor(publication.organization)
        article = Article.new(author: author, publication: publication, slug: "canopy-story-#{i}")
        workflow = EditorialWorkflow.new(author: author)
        workflow.save_draft(article, title: "#{TOPICS[i % TOPICS.size]} — Dispatch #{i + 1}", body: "Our #{publication.name} team followed the river after the autumn storm.\n\nNeighbors shared observations about access, wildlife, and repairs. Café volunteers brought maps; readers asked: “What happens next?”\n\nThe next survey will compare these findings with last season’s field notes.")
        reviewer = editor(publication.organization)
        reviewer_workflow = EditorialWorkflow.new(author: reviewer)
        if i.zero?
          workflow.submit(article, reviewer: reviewer)
          reviewer_workflow.decide(article.latest_revision.review_assignments.first, outcome: 'changes_requested', notes: 'Include wheelchair access at the bridge.')
          workflow.save_draft(article, title: article.title, body: article.body + "\n\nThe accessible entrance is on the east bank.")
        end
        workflow.submit(article, reviewer: reviewer) unless i % 10 == 9
        if i % 10 < 8 && i != 2
          reviewer_workflow.decide(article.latest_revision.review_assignments.first, outcome: 'approved', notes: 'Sources and access notes checked.')
          if i == 1
            reviewer_workflow.schedule(article, at: @at + 1.day)
          else
            PublishArticle.new(author: reviewer).call(article)
          end
        end
        article.tags << @tags[i % @tags.size]
        CollectionArticle.create!(collection: @collections[@publications.index(publication)], article: article, position: i)
        parent = article.comments.create!(body: 'Could the next report include trail accessibility?', author: nil)
        (i.zero? ? 12 : 2).times { |j| article.comments.create!(parent: parent, author: author, body: "Field reply #{j + 1}: the east entrance is accessible; the west steps need repair.") }
        parent.update!(archived_at: @at - 1.day) if i.zero?
        article
      end
      Publication.create!(organization: @organizations.last, name: 'The Quiet Edition', slug: 'empty-publication')
    end

    def build_commerce
      @plans = @publications.map { |p| p.plans.create!(name: 'Monthly field membership', amount_cents: 1200) }
      @subscribers = Array.new(@size[:subscribers]) do |i|
        plan = @plans[i % @plans.size]
        subscriber = Subscriber.create!(organization: plan.publication.organization, name: "Reader #{i + 1}", email: "reader#{i}@example.test", preferences: { newsletter: i % 17 != 16, simulate_bounce: i % 13 == 0, topics: ['trails', 'community'], locale: i.even? ? 'en' : 'fr', accessibility: { large_text: i % 5 == 0 } })
        actor = editor(subscriber.organization)
        workflow = Billing::SubscriptionWorkflow.new(author: actor)
        subscription = workflow.activate(subscriber: subscriber, plan: plan)
        invoice = subscription.invoices.first
        invoice.update!(reference: i.zero? ? 'CANOPY-REFUND' : "CANOPY-#{i}")
        if i % 5 == 0
          Billing::CollectPayment.new.call(invoice: invoice, key: "seed-failed-#{i}", outcome: 'failure')
        end
        if i % 5 != 4
          payment = Billing::CollectPayment.new.call(invoice: invoice, key: "seed-paid-#{i}", method: i.even? ? 'card' : 'bank')
          Billing::RefundPayment.new.call(payment: payment, amount_cents: 300, key: 'seed-partial-refund', reason: 'Partial credit for delivery delay') if i.zero?
        else
          invoice.update!(due_at: @at - 1.day)
        end
        workflow.cancel(subscription) if i % 11 == 10
        subscriber
      end
      subscriber = @subscribers.first
      invoice = Billing::Invoice.create!(author: editor(subscriber.organization), subscriber: subscriber, reference: 'CANOPY-OVERDUE', due_at: @at - 7.days)
      invoice.line_items.create!(description: 'Annual archive supplement', amount_cents: 2500)
    end

    def build_audience
      @campaigns = @publications.filter_map do |publication|
        article = publication.articles.where(state: 'published').first
        next unless article
        campaign = publication.campaigns.create!(article: article, subject: "Autumn dispatch · #{publication.name}")
        Newsletter::SendCampaign.new.call(campaign: campaign, author: editor(publication.organization))
        campaign.deliveries.find_each { |delivery| Newsletter::DeliverJob.perform_now(delivery.id) }
        campaign
      end
      deliveries = Newsletter::Delivery.where(state: 'delivered').includes(:campaign).to_a
      if deliveries.any?
        rows = Array.new(@size[:events]) do |i|
          delivery = deliveries[@rng.rand(deliveries.size)]
          { subscriber_id: delivery.subscriber_id, article_id: delivery.campaign.article_id, delivery_id: delivery.id, kind: %w[open click read][i % 3], metadata: { source: 'newsletter', device: { kind: i.even? ? 'mobile' : 'desktop' }, note: i.zero? ? 'é🌿' * 2048 : nil }, created_at: @at - (i % 90).days, updated_at: @at }
        end
        rows.each_slice(1000) { |batch| EngagementEvent.insert_all!(batch) }
      end
      WebhookDelivery.limit(3).each do |delivery|
        WebhookDeliveryJob.perform_now(delivery.id)
        WebhookDeliveryJob.perform_now(delivery.id)
      end
    end

    def build_syndication
      @organizations.each do |organization|
        partners = [['Valley Courier', 'valley-courier'], ['Hill Times', 'hill-times']].map do |name, slug|
          organization.syndication_partners.create!(name: name, contact_email: "desk@#{slug}.example.test",
            api_token: "canopy-testbed-partner-#{organization.slug}-#{slug}", webhook_secret: "fictional-partner-secret-#{organization.slug}-#{slug}")
        end
        workflow = Syndication::GrantLicense.new(author: editor(organization))
        published = Article.joins(:publication).where(publications: { organization_id: organization.id }, state: 'published').order(:id).to_a
        published.each_with_index do |article, i|
          exclusive = article.slug == 'canopy-story-3'
          next unless exclusive || i % 4 == 0
          license = workflow.call(partner: partners[exclusive ? 1 : 0], article: article, territory: exclusive ? 'worldwide' : 'US',
            starts_on: @at.to_date - 10, ends_on: @at.to_date + 60, fee_cents: exclusive ? 25_000 : 8_000, exclusive: exclusive)
          Syndication::RecordUsage.new.call(partner: license.partner, rows: [{ license_id: license.id, period_start: (@at.to_date - 10).beginning_of_month, pickups: 3 + i, impressions: 1_200 * (i + 1) }])
        end
        revocable = partners.first.licenses.where.not(article_id: published.first&.id).order(:id).last
        Syndication::RevokeLicense.new(author: editor(organization)).call(revocable) if revocable
      end
    end

    # The September run is started mid-month at the reference time so every
    # seeded earning lands in it. Transfers are submitted explicitly: the seed
    # transaction drops after_commit jobs into the test adapter.
    def build_payouts
      @organizations.each do |organization|
        run = Payouts::StartPayoutRun.new(author: editor(organization)).call(organization: organization, period_start: @at.to_date)
        Payouts::FinalizePayoutRun.new(author: editor(organization)).call(run)
        run.statements.includes(:transfer).order(:id).each do |statement|
          @scenarios[:held_statement] ||= statement.payee.display_name if statement.held?
          next unless statement.transfer
          Payouts::SubmitTransferJob.perform_now(statement.transfer.id)
          next unless statement.transfer.reload.failed?
          @scenarios[:retried_transfer] ||= statement.transfer.idempotency_key
          Payouts::SubmitTransferJob.perform_now(statement.transfer.id)
        end
      end
    end

    def build_support
      @subscribers.each_with_index do |subscriber, i|
        next unless i % 10 == 0
        ticket = subscriber.tickets.create!(title: "Renewal question from #{subscriber.name}", subject: subscriber.invoices.first)
        ticket.messages.create!(body: "My first payment failed.\nCould you check the renewal and any credit?", author: nil)
        ticket.messages.create!(body: 'We found the retry in your invoice history and are checking the credit.', author: editor(subscriber.organization))
        Support::ResolveTicket.new.call(ticket: ticket, author: editor(subscriber.organization)) unless i.zero?
      end
    end
  end
end
