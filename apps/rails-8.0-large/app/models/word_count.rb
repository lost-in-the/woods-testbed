# A plain Ruby object under app/models — which is exactly what PoroExtractor
# looks for, and what distinguishes a `poro` unit from a `model` unit.
class WordCount
  WORD = /[[:alpha:]']+/

  def initialize(text)
    @text = text.to_s
  end

  def total
    @text.scan(WORD).size
  end

  def unique
    @text.downcase.scan(WORD).uniq.size
  end
end
