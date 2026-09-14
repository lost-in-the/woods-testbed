module RequiresAuthor
  extend ActiveSupport::Concern
  included do
    before_action :require_author
  end
  private
  def require_author
    @current_author = Author.find_by(id: session[:author_id])
    redirect_to demo_session_path if @current_author.nil?
  end
end
