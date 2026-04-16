class LessonTimeSlot < ActiveRecord::Base
  has_enumeration_for :period, with: Periods, skip_validation: true

  validates :period, :class_number, :start_time, :end_time, presence: true
  validates :class_number, uniqueness: { scope: :period }
  validates :start_time, :end_time, format: { with: /\A\d{2}:\d{2}\z/ }

  scope :by_period, ->(period) { where(period: period) }
  scope :ordered, -> { order(:class_number) }

  def start_hour_min
    start_time.split(':').map(&:to_i)
  end

  def end_hour_min
    end_time.split(':').map(&:to_i)
  end
end
