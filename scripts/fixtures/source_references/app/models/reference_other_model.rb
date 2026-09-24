class ReferenceOtherModel < ApplicationRecord
  self.table_name = 'articles'
  include ReferenceConcern
end
