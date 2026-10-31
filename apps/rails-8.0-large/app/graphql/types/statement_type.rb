module Types
  class StatementType < GraphQL::Schema::Object
    description "A contributor payout statement"

    field :id, ID, null: false
    field :status, String, null: false
    field :total_cents, Integer, null: false
    field :currency, String, null: false
    field :payee_name, String, null: false
    field :hold_reason, String, null: true

    def payee_name = object.payee.display_name
  end
end
