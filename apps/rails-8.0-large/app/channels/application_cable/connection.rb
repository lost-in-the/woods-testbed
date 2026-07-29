module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_author

    def connect
      self.current_author = Author.find_by(id: cookies.signed[:author_id])
      reject_unauthorized_connection if current_author.nil?
    end
  end
end
