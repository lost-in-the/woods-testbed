# frozen_string_literal: true

class ReferencePromotableType < GraphQL::Schema::Object
  field :hello, String, null: false
  def hello
    "promoted"
  end
end
