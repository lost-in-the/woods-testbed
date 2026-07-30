class ArticlesController < ApplicationController
  include RequiresAuthor

  # Rails.cache.fetch is what makes this a `caching` unit — CachingExtractor
  # scans controllers, models and .erb views for cache calls.
  def index
    @articles = Rails.cache.fetch("articles/published", expires_in: 5.minutes) do
      Article.published.not_archived.to_a
    end
  end

  def show
    @article = Article.find(params[:id])
  end

  def create
    result = PublishArticle.new(author: @current_author).call(article_params)
    redirect_to article_path(result)
  end

  private

  def article_params
    params.require(:article).permit(:title, :body)
  end
end
