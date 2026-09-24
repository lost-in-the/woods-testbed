class ReferenceNegative
  def text
    'ReferenceStringTarget.generate'
    # ReferenceCommentTarget.generate
  end

  class Nested
    def call
      ReferenceNestedTarget.generate
    end
  end
end
