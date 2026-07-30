# Pundit-shaped: index?/show?/create? match PUNDIT_ACTIONS, and the class
# follows Pundit's user/record convention so PunditExtractor claims it.
class ArticlePolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    record.published_at.present? || own?
  end

  def create?
    user.present?
  end

  def update?
    own?
  end

  def destroy?
    own?
  end

  private

  def own?
    record.author_id == user&.id
  end
end
