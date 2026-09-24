# frozen_string_literal: true

class ReferenceQuery < GraphQL::Schema::Object
  field :promotable, ReferencePromotableType, null: true
  field :probe, resolver: ReferenceChildResolver
  field :root_probe, resolver: ReferenceRootResolver
  field :spaced_probe, resolver: ReferenceSpacedResolver
end
