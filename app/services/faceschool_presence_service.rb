class FaceschoolPresenceService

  def initialize(params)
    @student_api_code = params[:studentId]
    @date_str = params[:date]
    @device = params[:device]
    @check_in_str = params[:checkIn]
    @check_out_str = params[:checkOut]
    @marked = []
  end

  def call
    return missing_params_error unless @student_api_code.present? && @date_str.present?

    parse_times!

    return missing_times_error unless @check_in || @check_out

    student = Student.find_by(api_code: @student_api_code)
    return student_not_found_error unless student

    enrollments = active_enrollments(student)
    return no_enrollment_error if enrollments.empty?

    ActiveRecord::Base.transaction do
      enrollments.each do |enrollment|
        classroom = enrollment.classrooms_grade.classroom
        process_classroom(student, classroom)
      end
    end

    success_response
  rescue ActiveRecord::RecordInvalid => e
    { success: false, errors: e.message, status: :unprocessable_entity }
  rescue ArgumentError => e
    { success: false, errors: "Formato de data/hora inválido: #{e.message}", status: :bad_request }
  end

  private

  def parse_times!
    @date = Date.parse(@date_str)
    @check_in = @check_in_str.present? ? Time.zone.parse(@check_in_str) : nil
    @check_out = @check_out_str.present? ? Time.zone.parse(@check_out_str) : nil
  end

  def active_enrollments(student)
    StudentEnrollmentClassroom.by_student(student.id)
                              .by_date(@date)
                              .active
                              .includes(classrooms_grade: { classroom: :unity })
  end

  def process_classroom(student, classroom)
    daily_frequencies = DailyFrequency.by_classroom_id(classroom.id)
                                      .by_frequency_date(@date)

    if daily_frequencies.any?
      process_existing_frequencies(student, daily_frequencies)
    else
      create_and_mark_frequencies(student, classroom)
    end
  end

  def process_existing_frequencies(student, daily_frequencies)
    daily_frequencies.each do |df|
      period = df.period.to_i

      should_mark = if df.class_number.present?
                      class_covered?(period, df.class_number)
                    else
                      any_class_covered?(period)
                    end

      mark_student_present(df, student) if should_mark
    end
  end

  def create_and_mark_frequencies(student, classroom)
    period = classroom.period.to_i
    covered = covered_class_numbers(period)
    return if covered.empty?

    school_calendar = CurrentSchoolCalendarFetcher.new(classroom.unity, classroom).fetch
    return unless school_calendar

    allocations = lesson_allocations(classroom)

    if allocations.any?
      create_by_discipline_frequencies(student, classroom, school_calendar, covered, allocations)
    else
      create_general_frequency(student, classroom, school_calendar)
    end
  end

  def covered_class_numbers(period)
    schedule = schedule_for_period(period)
    return [] unless schedule

    schedule.keys.select { |class_number| class_covered?(period, class_number) }
  end

  def lesson_allocations(classroom)
    weekday_name = @date.strftime('%A').downcase

    LessonsBoardLessonWeekday
      .includes(lessons_board_lesson: :lessons_board, teacher_discipline_classroom: [:teacher, :discipline])
      .by_classroom(classroom.id)
      .by_weekday(weekday_name)
      .order('lessons_board_lessons.lesson_number')
  end

  def create_by_discipline_frequencies(student, classroom, school_calendar, covered, allocations)
    covered.each do |class_number|
      allocation = allocations.detect { |a| a.lessons_board_lesson.lesson_number.to_i == class_number }
      next unless allocation

      tdc = allocation.teacher_discipline_classroom

      daily_frequency = find_or_create_daily_frequency(
        classroom, school_calendar, tdc.discipline_id, class_number, tdc.teacher_id
      )

      next unless daily_frequency&.persisted?

      mark_student_present(daily_frequency, student)
    end
  end

  def create_general_frequency(student, classroom, school_calendar)
    daily_frequency = find_or_create_daily_frequency(classroom, school_calendar, nil, nil, nil)

    return unless daily_frequency&.persisted?

    mark_student_present(daily_frequency, student)
  end

  def find_or_create_daily_frequency(classroom, school_calendar, discipline_id, class_number, teacher_id)
    DailyFrequency.create_with(
      unity_id: classroom.unity_id,
      school_calendar: school_calendar,
      owner_teacher_id: teacher_id,
      origin: OriginTypes::API_V2
    ).find_or_create_by(
      classroom_id: classroom.id,
      frequency_date: @date,
      period: classroom.period,
      discipline_id: discipline_id,
      class_number: class_number
    )
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def class_covered?(period, class_number)
    schedule = schedule_for_period(period)
    return false unless schedule

    times = schedule[class_number]
    return false unless times

    class_start = build_time(times[:start])
    class_end = build_time(times[:finish])
    tolerance = tolerance_minutes.minutes

    check_in_ok = @check_in.nil? || @check_in <= (class_start + tolerance)
    check_out_ok = @check_out.nil? || @check_out >= (class_end - tolerance)

    check_in_ok && check_out_ok
  end

  def any_class_covered?(period)
    schedule = schedule_for_period(period)
    return false unless schedule

    schedule.keys.any? { |class_number| class_covered?(period, class_number) }
  end

  def schedule_for_period(period)
    @schedules ||= {}
    @schedules[period] ||= load_schedule(period)
  end

  def load_schedule(period)
    if period == Periods::FULL.to_i
      return load_full_day_schedule
    end

    slots = LessonTimeSlot.by_period(period).ordered
    return nil if slots.empty?

    build_schedule_hash(slots)
  end

  def load_full_day_schedule
    morning = LessonTimeSlot.by_period(Periods::MATUTINAL.to_i).ordered
    afternoon = LessonTimeSlot.by_period(Periods::VESPERTINE.to_i).ordered
    return nil if morning.empty? && afternoon.empty?

    schedule = build_schedule_hash(morning)
    offset = morning.size
    afternoon.each do |slot|
      schedule[slot.class_number + offset] = {
        start: slot.start_hour_min,
        finish: slot.end_hour_min
      }
    end
    schedule
  end

  def build_schedule_hash(slots)
    slots.each_with_object({}) do |slot, hash|
      hash[slot.class_number] = {
        start: slot.start_hour_min,
        finish: slot.end_hour_min
      }
    end
  end

  def tolerance_minutes
    @tolerance_minutes ||= GeneralConfiguration.first&.faceschool_tolerance_minutes || 0
  end

  def build_time(hour_min)
    Time.zone.local(@date.year, @date.month, @date.day, hour_min[0], hour_min[1])
  end

  def mark_student_present(daily_frequency, student)
    dfs = DailyFrequencyStudent.find_or_initialize_by(
      daily_frequency_id: daily_frequency.id,
      student_id: student.id
    )

    return if dfs.persisted?

    dfs.present = true
    dfs.active = true
    dfs.save!

    @marked << {
      classroom_id: daily_frequency.classroom_id,
      class_number: daily_frequency.class_number,
      discipline_id: daily_frequency.discipline_id
    }
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def success_response
    {
      success: true,
      student_id: @student_api_code,
      date: @date_str,
      marked_count: @marked.size,
      marked_classes: @marked
    }
  end

  def missing_params_error
    { success: false, errors: 'studentId e date são obrigatórios', status: :bad_request }
  end

  def missing_times_error
    { success: false, errors: 'checkIn ou checkOut deve ser informado', status: :bad_request }
  end

  def student_not_found_error
    { success: false, errors: 'Aluno não encontrado', status: :not_found }
  end

  def no_enrollment_error
    { success: false, errors: 'Nenhuma matrícula ativa encontrada para o aluno na data', status: :not_found }
  end
end
