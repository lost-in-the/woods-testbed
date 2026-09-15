class ApplicationController < ActionController::Base
  helper_method :current_author, :current_organization, :editor?
  rescue_from Pundit::NotAuthorizedError, with: -> { render plain: 'You do not have access to this action.', status: :forbidden }
  rescue_from ActiveRecord::RecordNotFound, with: -> { render plain: 'Record not found.', status: :not_found }
  rescue_from ActiveRecord::RecordInvalid, EditorialWorkflow::InvalidTransition, ActiveRecord::StaleObjectError, ArgumentError, with: :invalid_request
  def current_author
    @current_author ||= Author.find_by(id: session[:author_id])
  end
  def current_organization
    @current_organization ||= current_author&.organizations&.find_by(id: session[:organization_id]) || current_author&.organizations&.first
  end
  def editor? = current_author && current_organization && current_author.editor_of?(current_organization)
  private
  def require_session
    redirect_to demo_session_path unless current_author && current_organization
  end
  def require_editor
    raise Pundit::NotAuthorizedError unless editor?
  end
  def page_offset = ([params[:page].to_i, 1].max - 1) * 25
  def invalid_request(error)
    render plain: error.message, status: :unprocessable_entity
  end
end
