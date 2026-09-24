module ReferenceSpace
  class ReferenceTarget
    def self.generate
      raise 'Acceptance must never execute source-reference target methods'
    end
  end
end
