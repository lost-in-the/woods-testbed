class ArticlePolicy < ApplicationPolicy
  def index? = user.present?
  def show? = member? && (record.state == 'published' || update?)
  def create? = member?
  def update? = member? && (record.author_id == user.id || review?)
  def destroy? = update?
  def review? = user.present? && record.publication.present? && user.editor_of?(record.publication.organization)
  def publish? = review?
  private
  def member?
    user.present? && user.memberships.exists?(organization_id: record.publication&.organization_id)
  end
end
