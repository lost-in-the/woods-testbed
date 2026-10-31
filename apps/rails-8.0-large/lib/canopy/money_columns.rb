# Lives in lib/ but is included by models as a concern.
module Canopy
  module MoneyColumns
    extend ActiveSupport::Concern

    def self.format(cents, currency)
      units, remainder = cents.to_i.abs.divmod(100)
      sign = cents.to_i.negative? ? '-' : ''
      "#{sign}$#{units.to_s.reverse.scan(/\d{1,3}/).join(',').reverse}.#{remainder.to_s.rjust(2, '0')} #{currency}"
    end

    class_methods do
      def money_column(attribute)
        validates attribute, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
        define_method("#{attribute.to_s.delete_suffix('_cents')}_display") do
          Canopy::MoneyColumns.format(public_send(attribute), try(:currency) || 'USD')
        end
      end
    end
  end
end
