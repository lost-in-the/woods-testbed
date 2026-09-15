class RecordActivity
  def call(organization:, actor:, subject:, action:)
    event = organization.activity_events.create!(actor: actor, subject: subject, action: action)
    organization.webhook_endpoints.find_each do |endpoint|
      endpoint.webhook_deliveries.create!(activity_event: event, payload: { event: action, subject: { type: subject.class.name, id: subject.id } })
    end
    event
  end
end
