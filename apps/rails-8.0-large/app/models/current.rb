# Request- and job-scoped tenant. Rails resets it between requests and jobs.
class Current < ActiveSupport::CurrentAttributes
  attribute :organization, :author, :partner
end
