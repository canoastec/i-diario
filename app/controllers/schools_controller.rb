class SchoolsController < ApplicationController
  respond_to :json

  def index
    begin
      codes = result["info-escolas"].map { |r| r["cod_escola"] }

      @unities = Unity.where(api_code: codes)
    rescue Exception => e
      Rails.logger.error("[#{e.class}] #{e.message}\n#{(e.backtrace || []).first(20).join("\n")}")

      render json: { error: e.message }, status: :not_found
    end
  end

  protected

  def result
    api.fetch_all
  end

  def api
    @api ||= IeducarApi::Schools.new current_configuration.to_api
  end
end
