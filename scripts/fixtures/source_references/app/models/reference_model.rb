class ReferenceModel < ApplicationRecord
  self.table_name = 'articles'
  include ReferenceConcern

  before_validation do
    ReferenceTarget.generate
  end
end
