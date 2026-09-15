class GraphqlController < ApplicationController
  before_action :require_session
  def create
    render json: TestbedSchema.execute(params.require(:query), variables: params[:variables]&.to_unsafe_h || {}, context: { author: current_author, organization: current_organization })
  end
end
