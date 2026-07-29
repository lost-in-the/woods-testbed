# Base class for the variant's serializers.
#
# SerializerExtractor#serializer_file? recognises a serializer by *shape*, not by
# directory: `< ApplicationSerializer`, `< ActiveModel::Serializer`,
# `< Blueprinter::Base`, an `attributes :` DSL, and so on. A plain PORO sitting
# in app/serializers produces no unit at all — worth having a fixture pin down.
class ApplicationSerializer
  def initialize(record)
    @record = record
  end

  def self.attributes(*names)
    @attribute_names = names
  end

  def self.attribute_names
    @attribute_names || []
  end

  def as_json(*)
    self.class.attribute_names.to_h { |name| [name, public_send(name)] }
  end

  private

  attr_reader :record
end
