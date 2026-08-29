# G-1 wrapper fixture: the file's first class is Container, but this unit must
# extract as Domain::Container::Parser, not the wrapper. Sibling renderer.rb
# opens the same wrapper class, so the pair exercises the collision case.
module Domain
  class Container
    class Parser
      def self.call(source)
        source.to_s.strip
      end
    end
  end
end
