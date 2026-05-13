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

    @date = Date.parse(@date_str)
    @check_in = @check_in_str.present? ? Time.zone.parse(@check_in_str) : nil
    @check_out = @check_out_str.present? ? Time.zone.parse(@check_out_str) : nil

    student = Student.find_by(api_code: @student_api_code)
    return student_not_found_error unless student

    enrollments = active_enrollments(student)
    return no_enrollment_error if enrollments.empty?

    Audited.audit_class.as_user('FaceSchool') do
      ActiveRecord::Base.transaction do
        enrollments.each do |enrollment|
          classroom = enrollment.classrooms_grade.classroom
          process_classroom(student, classroom)
        end
      end
    end

    success_response
  rescue ActiveRecord::RecordInvalid => e
    { success: false, errors: e.message, status: :unprocessable_entity }
  rescue ArgumentError => e
    { success: false, errors: "Formato de data/hora inválido: #{e.message}", status: :bad_request }
  end

  private

  def active_enrollments(student)
    StudentEnrollmentClassroom.by_student(student.id)
                              .by_date(@date)
                              .active
                              .includes(classrooms_grade: { classroom: :unity })
  end

  def process_classroom(student, classroom)
    school_calendar = CurrentSchoolCalendarFetcher.new(classroom.unity, classroom).fetch
    return unless school_calendar

    create_general_frequency(student, classroom, school_calendar)
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
      origin: OriginTypes::FACESCHOOL
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

  def mark_student_present(daily_frequency, student)
    dfs = DailyFrequencyStudent.find_or_initialize_by(
      daily_frequency_id: daily_frequency.id,
      student_id: student.id
    )

    return if dfs.persisted? && dfs.present? && dfs.active?

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
      check_in: @check_in_str,
      check_out: @check_out_str,
      marked_count: @marked.size,
      marked_classes: @marked
    }
  end

  def missing_params_error
    { success: false, errors: 'studentId e date são obrigatórios', status: :bad_request }
  end

  def student_not_found_error
    { success: false, errors: 'Aluno não encontrado', status: :not_found }
  end

  def no_enrollment_error
    { success: false, errors: 'Nenhuma matrícula ativa encontrada para o aluno na data', status: :not_found }
  end
end
