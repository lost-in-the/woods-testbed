# frozen_string_literal: true

class ReferenceSpacedResolver <  GraphQL::Schema::Resolver
  type String, null: false
  def resolve
    "spaced-ok"
  end
end
