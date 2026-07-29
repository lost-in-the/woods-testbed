# Idiomatic Pundit base.
#
# PunditExtractor#pundit_policy? identifies a Pundit policy by convention:
# `< ApplicationPolicy`, or `attr_reader :user` + `:record`, or
# `def initialize(user, ...)` alongside a predicate method. Naming the
# constructor args anything else (author/article, actor/subject) makes the
# policy invisible to that extractor — so the kernel follows the convention.
class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def index?
    false
  end

  def show?
    false
  end

  def create?
    false
  end

  def update?
    false
  end

  def destroy?
    false
  end
end
