module Newsletter
  class SendCampaign
    def call(campaign:, author:)
      raise Pundit::NotAuthorizedError unless author&.editor_of?(campaign.publication.organization)
      campaign.with_lock do
        return if campaign.state == 'sent'
        campaign.recipients.find_each do |subscriber|
          next if subscriber.preferences['newsletter'] == false
          campaign.deliveries.find_or_create_by!(subscriber: subscriber)
        end
        campaign.update!(state: 'sent')
      end
      campaign.deliveries.where(state: 'queued').find_each { |delivery| Newsletter::DeliverJob.perform_later(delivery.id) }
    end
  end
end
