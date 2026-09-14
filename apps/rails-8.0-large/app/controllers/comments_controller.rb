class CommentsController < ApplicationController
  before_action :require_session
  before_action :load_article
  def index
    @comments = @article.comments.recent.includes(:author).limit(25).offset(page_offset)
  end
  def create
    @article.comments.create!(body: params.require(:body), author: current_author, parent: params[:parent_id].present? ? @article.comments.find(params[:parent_id]) : nil)
    redirect_to article_comments_path(@article)
  end
  private
  def load_article
    @article = Article.find(params[:article_id])
    raise Pundit::NotAuthorizedError unless ArticlePolicy.new(current_author, @article).show?
  end
end
