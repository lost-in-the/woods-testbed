class ArticlesController < ApplicationController
  def index
    @articles = Article.published.not_archived
  end

  def show
    @article = Article.find(params[:id])
  end
end
