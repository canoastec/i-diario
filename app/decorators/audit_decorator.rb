class AuditDecorator
  def initialize(record)
    self.record = record
  end

  delegate :action, :audited_changes, :auditable, :user, :username, :created_at, to: :record

  def display_user
    return 'FaceSchool' if faceschool_origin?
    return 'API V2' if api_v2_origin?

    user || username
  end

  def human_attribute_name(field)
    klass.human_attribute_name field
  end

  def klass
    @klass ||= record.auditable_type.constantize
  end

  def enumeration?(field)
    enumeration(field).present?
  end

  def enumeration(field)
    klass.enumerations[field]
  end

  def enumeration_t(field, value)
    enumeration(field).t value
  end

  def parse(field, values, position)
    value = if values.is_a?(Array)
              values.send(position)
            else
              values
            end

    relation = field.to_s.gsub(/_id/, '').to_sym
    association = klass.reflect_on_association(relation)

    if enumeration?(field)
      enumeration_t field, value
    elsif value == false || value == true
      I18n.t "boolean.#{value}"
    elsif value.is_a?(Date) || value.is_a?(Time)
      I18n.l value
    elsif field == :encrypted_password
      "*********"
    elsif field.match(/_id/) && association.present?
      # Sometimes the record used in the relation doesn't exist anymore
      begin
        class_name = if association.try(:class_name)
          association.class_name
        else
          relation
        end

        class_name.to_s.constantize.find(value)
      rescue
        value
      end
    else
      value
    end
  end

  protected

  attr_accessor :record

  def faceschool_origin?
    return false unless auditable.respond_to?(:daily_frequency)

    auditable.daily_frequency&.origin == OriginTypes::FACESCHOOL
  end

  def api_v2_origin?
    return false unless auditable.respond_to?(:daily_frequency)

    auditable.daily_frequency&.origin == OriginTypes::API_V2
  end
end
