class MoneyComponent < ApplicationComponent
  def initialize(cents:, currency:)
    @cents = cents
    @currency = currency
  end

  def view_template
    plain Canopy::MoneyColumns.format(@cents, @currency)
  end
end
