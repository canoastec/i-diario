module Api
  module V2
    class FaceschoolPresencesController < Api::V2::BaseController
      def create
        service = FaceschoolPresenceService.new(presence_params)
        result = service.call

        if result[:success]
          render json: result, status: :created
        else
          render json: { errors: result[:errors] }, status: (result[:status] || :unprocessable_entity)
        end
      end

      private

      def presence_params
        params.permit(:studentId, :date, :device, :checkIn, :checkOut)
      end
    end
  end
end
