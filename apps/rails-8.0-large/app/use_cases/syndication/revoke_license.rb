module Syndication
  class RevokeLicense
    def initialize(author:)
      @author = author
    end

    def call(license)
      organization = license.partner.organization
      raise Pundit::NotAuthorizedError unless @author&.editor_of?(organization)
      license.update!(revoked_at: Time.current)
      license
    end
  end
end
