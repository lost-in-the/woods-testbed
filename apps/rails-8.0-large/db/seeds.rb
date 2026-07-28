3.times { |i| Account.find_or_create_by!(name: "Account #{i + 1}") }
