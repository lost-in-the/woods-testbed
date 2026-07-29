# Controller concern, included by two controllers.
#
# Lives in app/controllers/concerns so ConcernExtractor picks it up from a
# different directory than the model concerns — the extractor discovers every
# `**/concerns` dir under app/, and having only model concerns would leave that
# untested.
module RequiresAuthor
  extend ActiveSupport::Concern

  included do
    before_action :require_author
  end

  private

  def require_author
    @current_author = Author.find_by(id: session[:author_id])
    head :forbidden if @current_author.nil?
  end
end
