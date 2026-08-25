module Api
  module V2
    class FaceschoolPresencesController < Api::V2::BaseController
      def create
        service = FaceschoolPresenceService.new(presence_params)
        result = service.call

        if result[:success]
          render json: result.except(:status), status: :created
        else
          render json: error_payload(result), status: (result[:status] || :unprocessable_entity)
        end
      end

      private

      def presence_params
        params.permit(:studentId, :date, :device, :checkIn, :checkOut)
      end

      def error_payload(result)
        payload = { errors: result[:errors] }
        payload[:reasons] = result[:reasons] if result[:reasons].present?
        payload[:student_id] = result[:student_id] if result.key?(:student_id)
        payload[:date] = result[:date] if result.key?(:date)
        payload[:marked_count] = result[:marked_count] if result.key?(:marked_count)
        payload
      end
    end
  end
end
