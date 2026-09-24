# frozen_string_literal: true

class ReferenceRootResolver < ::GraphQL::Schema::Resolver
  type String, null: false
  def resolve
    "root-ok"
  end
end
