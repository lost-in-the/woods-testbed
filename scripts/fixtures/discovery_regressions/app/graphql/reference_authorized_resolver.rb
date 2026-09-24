# frozen_string_literal: true

class ReferenceAuthorizedResolver < GraphQL::Schema::Resolver
  type String, null: false
  def resolve
    "fixture-ok"
  end
end
