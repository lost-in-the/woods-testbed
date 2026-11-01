class PublicArticlesController < ApplicationController
  include CurrentTenant
  def show
    @article = Article.published.not_archived.find_by!(slug: params[:slug])
  end
end
