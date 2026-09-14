class CollectionsController < ApplicationController
  before_action :require_session
  before_action :require_editor
  def index
    @collections = scope.includes(:publication).order(:name).limit(25).offset(page_offset)
  end
  def show
    @collection = scope.find(params[:id])
    @placements = @collection.collection_articles.includes(:article).limit(25).offset(page_offset)
    @articles = @collection.publication.articles.order(:title).limit(100)
  end
  def create
    publication = current_organization.publications.find(params.require(:publication_id))
    collection = publication.collections.create!(name: params.require(:name))
    redirect_to collection
  end
  def update
    collection = scope.find(params[:id])
    article = collection.publication.articles.find(params.require(:article_id))
    collection.with_lock do
      placement = collection.collection_articles.find_or_initialize_by(article: article)
      placement.update!(position: params.require(:position))
      if params[:tag].present?
        tag = Tag.find_or_create_by!(name: params[:tag].strip.downcase)
        article.article_tags.find_or_create_by!(tag: tag)
      end
    end
    redirect_to collection
  end
  private
  def scope = Collection.joins(:publication).where(publications: { organization_id: current_organization.id })
end
