# Included by each controller rather than once in ApplicationController, the
# way large apps accumulate a per-controller include of their tenant concern.
module CurrentTenant
  extend ActiveSupport::Concern
  included do
    before_action :assign_current_tenant
  end
  private
  def assign_current_tenant
    Current.author = current_author
    Current.organization = current_organization
  end
end
