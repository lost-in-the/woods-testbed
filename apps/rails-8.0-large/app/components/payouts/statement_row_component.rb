module Payouts
  class StatementRowComponent < ApplicationComponent
    def initialize(statement:)
      @statement = statement
    end

    def view_template
      tr do
        td { link_to @statement.payee.display_name, payouts_statement_path(@statement) }
        td { render StatusBadgeComponent.new(status: @statement.status) }
        td { render MoneyComponent.new(cents: @statement.total_cents, currency: @statement.currency) }
        td(class: 'muted') { @statement.hold_reason&.humanize.to_s }
      end
    end
  end
end
