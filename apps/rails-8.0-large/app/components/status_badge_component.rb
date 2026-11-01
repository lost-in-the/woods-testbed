class StatusBadgeComponent < ApplicationComponent
  def initialize(status:)
    @status = status
  end

  def view_template
    span(class: 'badge') { @status.to_s.humanize }
  end
end
