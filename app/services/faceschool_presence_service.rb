class FaceschoolPresenceService
  def initialize(params)
    @student_api_code = params[:studentId]
    @date_str = params[:date]
    @device = params[:device]
    @check_in_str = params[:checkIn]
    @check_out_str = params[:checkOut]
    @marked = []
    @already_present = []
    @skip_reasons = []
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
      enrollments.each do |enrollment|
        classroom = enrollment.classrooms_grade.classroom
        process_classroom(student, classroom)
      end
    end

    return success_response if @marked.any? || @already_present.any?

    not_marked_error
  rescue ActiveRecord::RecordInvalid => e
    log_failure(e.message)
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

    unless school_calendar
      @skip_reasons << "Calendário escolar não encontrado para a turma #{classroom.id}"
      return
    end

    create_general_frequency(student, classroom, school_calendar)
  rescue ActiveRecord::RecordInvalid => e
    # Não deixa uma turma derrubar as demais (regressão do #9830 com transaction + raise).
    @skip_reasons << "Turma #{classroom.id} (#{classroom.description}): #{e.message}"
  end

  def create_general_frequency(student, classroom, school_calendar)
    daily_frequency = find_or_create_daily_frequency(classroom, school_calendar)

    unless daily_frequency&.persisted?
      reason = if daily_frequency&.errors&.any?
                 daily_frequency.errors.full_messages.to_sentence
               else
                 'não foi possível criar/encontrar a frequência'
               end
      @skip_reasons << "Turma #{classroom.id} (#{classroom.description}): #{reason}"
      return
    end

    mark_student_present(daily_frequency, student)
  end

  # Mesmo padrão de antes do #9830 (e do DailyFrequenciesCreator):
  # find_or_create_by NÃO levanta erro de validação — só deixa persisted? false.
  def find_or_create_daily_frequency(classroom, school_calendar)
    DailyFrequency.create_with(
      unity_id: classroom.unity_id,
      school_calendar: school_calendar,
      owner_teacher_id: nil,
      origin: OriginTypes::FACESCHOOL
    ).find_or_create_by(
      classroom_id: classroom.id,
      frequency_date: @date,
      period: classroom.period,
      discipline_id: nil,
      class_number: nil
    )
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def mark_student_present(daily_frequency, student)
    dfs = DailyFrequencyStudent.find_or_initialize_by(
      daily_frequency_id: daily_frequency.id,
      student_id: student.id
    )

    if dfs.persisted? && dfs.present? && dfs.active?
      track_already_present(daily_frequency)
      return
    end

    dfs.present = true
    dfs.active = true
    dfs.save!

    @marked << presence_payload(daily_frequency)
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def track_already_present(daily_frequency)
    @already_present << presence_payload(daily_frequency)
  end

  def presence_payload(daily_frequency)
    {
      classroom_id: daily_frequency.classroom_id,
      class_number: daily_frequency.class_number,
      discipline_id: daily_frequency.discipline_id
    }
  end

  def success_response
    {
      success: true,
      student_id: @student_api_code,
      date: @date_str,
      check_in: @check_in_str,
      check_out: @check_out_str,
      marked_count: @marked.size,
      marked_classes: @marked,
      already_present_count: @already_present.size,
      already_present_classes: @already_present
    }
  end

  def not_marked_error
    errors = if @skip_reasons.any?
               @skip_reasons.join('; ')
             else
               'Nenhuma presença foi registrada para o aluno na data'
             end

    log_failure(errors)

    {
      success: false,
      errors: errors,
      reasons: @skip_reasons,
      student_id: @student_api_code,
      date: @date_str,
      marked_count: 0,
      status: :unprocessable_entity
    }
  end

  def log_failure(message)
    Rails.logger.warn(
      "[FaceSchool] Presença não registrada student_id=#{@student_api_code} date=#{@date_str}: #{message}"
    )
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
