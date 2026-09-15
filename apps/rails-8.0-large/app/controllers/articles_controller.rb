class ArticlesController < ApplicationController
  include RequiresAuthor
  before_action :require_session
  before_action :load_article, only: %i[show edit update submit decide publish schedule]
  def index
    @articles = Article.joins(:publication).where(publications: { organization_id: current_organization.id })
    @articles = @articles.where(author: current_author).or(@articles.where(state: 'published')) unless editor?
    @articles = @articles.where(state: params[:state]) if params[:state].present?
    @articles = @articles.where('articles.title LIKE ?', "%#{Article.sanitize_sql_like(params[:q].to_s)}%") if params[:q].present?
    @articles = @articles.includes(:author, :publication).order(updated_at: :desc).limit(25).offset(page_offset)
    # Keep a real cache extraction fixture, scoped and invalidated on publish.
    @published_count = current_organization.publications.sum do |publication|
      Rails.cache.fetch("articles/published/#{publication.id}", expires_in: 5.minutes) { publication.articles.published.not_archived.count }
    end
  end
  def show
    @revisions = @article.revisions.order(number: :desc).includes(review_assignments: [:reviewer, :review_decision])
  end
  def new
    @article = Article.new(author: current_author, publication: current_organization.publications.first)
  end
  def create
    publication = current_organization.publications.find(params.require(:article).require(:publication_id))
    @article = Article.new(author: current_author, publication: publication)
    workflow.save_draft(@article, article_params)
    redirect_to @article
  end
  def edit
    workflow.authorize!(@article, :update?)
  end
  def update
    workflow.save_draft(@article, article_params)
    redirect_to @article
  end
  def submit
    workflow.submit(@article, reviewer: current_organization.authors.find(params.require(:reviewer_id)))
    redirect_to @article
  end
  def decide
    assignment = @article.revisions.joins(:review_assignments).where(review_assignments: { id: params[:assignment_id] }).first!.review_assignments.find(params[:assignment_id])
    workflow.decide(assignment, outcome: params.require(:outcome), notes: params[:notes])
    redirect_to @article
  end
  def publish
    PublishArticle.new(author: current_author).call(@article)
    redirect_to @article
  end
  def schedule
    workflow.schedule(@article, at: Time.zone.parse(params.require(:scheduled_at)))
    redirect_to @article
  end
  private
  def load_article
    @article = Article.joins(:publication).where(publications: { organization_id: current_organization&.id }).find(params[:id])
    workflow.authorize!(@article, :show?)
  end
  def workflow = EditorialWorkflow.new(author: current_author)
  def article_params = params.require(:article).permit(:title, :body).to_h.symbolize_keys
end
