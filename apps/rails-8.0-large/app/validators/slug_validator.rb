class SlugValidator < ActiveModel::EachValidator
  FORMAT = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

  def validate_each(record, attribute, value)
    return if value.blank? || FORMAT.match?(value)

    record.errors.add(attribute, "must be lowercase words separated by hyphens")
  end
end
