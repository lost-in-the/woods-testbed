module Types
  class QueryType < GraphQL::Schema::Object
    field :articles, resolver: Resolvers::ArticlesResolver
    field :payout_statement, Types::StatementType, null: true do
      argument :id, ID, required: true
    end

    def payout_statement(id:)
      statement = Payouts::Statement.joins(:payout_run)
        .where(payouts_payout_runs: { organization_id: Current.organization&.id }).find_by(id: id)
      raise GraphQL::ExecutionError, 'Statement not found' unless statement && Payouts::StatementPolicy.new(context[:author], statement).show?
      statement
    end
  end
end
