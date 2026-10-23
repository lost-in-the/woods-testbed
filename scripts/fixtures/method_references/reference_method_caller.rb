class ReferenceMethodCaller
  def call
    ReferenceTarget.generate
    @bare = ReferenceTarget
    consume(ReferenceTarget)
    ReferenceTarget.generate(ReferenceAlternateTarget)
    ReferenceTarget.new.call
    ReferenceTarget.send(:generate)
    ReferenceTarget.value += 1
    ReferenceTarget[0] ||= 1
    ReferenceTarget.missing_selector
    (ReferenceTarget).generate
    ((ReferenceTarget)).generate
    ReferenceTarget.()
    ReferenceTarget&.generate # rubocop:disable Lint/RedundantSafeNavigation -- Intentional selector fixture.
    ReferenceTarget::generate
    ReferenceTarget.value = 1
    ReferenceTarget[0]
    ReferenceTarget[0] = 1
    @neg = -ReferenceTarget
    (@bare = ReferenceTarget; ReferenceAlternateTarget).generate
    ReferenceTarget.generate(ReferenceAlternateTarget.generate)
    ReferenceTarget.generate { ReferenceAlternateTarget.generate }
    ReferenceSpace::ReferenceTarget.generate
    ReferenceTarget.ready?
    ReferenceTarget.save!
    ReferenceTarget.café
    ReferenceTarget + 1
  end

  def consume(value)
    value
  end

  def assignment_targets
    begin
      nil
    rescue => ReferenceTarget.value
      consume(nil)
    end
    begin
      nil
    rescue => ReferenceTarget[ReferenceAlternateTarget.generate]
      consume(nil)
    end
    begin
      nil
    rescue => ReferenceTarget.generate.value
      consume(nil)
    end
    for ReferenceTarget.value in []
      consume(nil)
    end
    for ReferenceTarget[ReferenceAlternateTarget.generate] in []
      consume(nil)
    end
    for ReferenceTarget.generate.value in []
      consume(nil)
    end
    for (ReferenceTarget.value, (ReferenceAlternateTarget[ReferenceTarget.generate], ReferenceTarget.generate.value)) in []
      consume(nil)
    end
  end
end
