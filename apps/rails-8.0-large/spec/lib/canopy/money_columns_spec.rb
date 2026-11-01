require 'rails_helper'

RSpec.describe Canopy::MoneyColumns do
  let(:model) do
    Class.new(ApplicationRecord) do
      self.table_name = 'billing_plans'
      def self.name = 'MoneyColumnsProbe'
      include Canopy::MoneyColumns
      money_column :amount_cents
    end
  end

  it 'formats cents with grouping and the currency code' do
    expect(described_class.format(123_456, 'USD')).to eq('$1,234.56 USD')
  end

  it 'rejects negative amounts and displays the amount' do
    expect(model.new(amount_cents: -1)).not_to be_valid
    expect(model.new(amount_cents: 1200, currency: 'USD').amount_display).to eq('$12.00 USD')
  end
end
