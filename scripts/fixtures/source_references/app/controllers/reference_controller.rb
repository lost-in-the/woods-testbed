class ReferenceController < ActionController::Base
  def show
    render plain: ReferenceTarget.generate
  end
end
