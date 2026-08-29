# A user record. Exists so console-SQL probes have a `users` table to lock —
# the MySQL dialect contract (gem PR lost-in-the/woods#248) is asserted
# against this exact table name.
class User < ApplicationRecord
  validates :email, presence: true, uniqueness: true
end
