# G-1 wrapper fixture: the file's first class is Container, but this unit must
# extract as Domain::Container::Renderer, not the wrapper. Sibling parser.rb
# opens the same wrapper class, so the pair exercises the collision case.
module Domain
  class Container
    class Renderer
      def self.call(template)
        template.to_s.upcase
      end
    end
  end
end
