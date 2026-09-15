class PublicArticlesController < ApplicationController
  def show
    @article = Article.published.not_archived.find_by!(slug: params[:slug])
  end
end
