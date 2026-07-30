class CommentsController < ApplicationController
  def index
    @article = Article.find(params[:article_id])
    @comments = @article.comments.recent
  end

  def create
    @article = Article.find(params[:article_id])
    @article.comments.create!(body: params[:body])
    redirect_to article_comments_path(@article)
  end
end
