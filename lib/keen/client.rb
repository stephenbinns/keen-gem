require 'keen/http'
require 'keen/version'
require 'openssl'
require 'multi_json'
require 'base64'

module Keen
  class Client
    attr_accessor :project_id, :api_key

    CONFIG = {
      :api_host => "api.keen.io",
      :api_port => 443,
      :api_version => "3.0",
      :api_sync_http_options => {
        :use_ssl => true,
        :verify_mode => OpenSSL::SSL::VERIFY_PEER,
        :verify_depth => 5,
        :ca_file => File.expand_path("../../../config/cacert.pem", __FILE__) },
      :api_async_http_options => {},
      :api_headers => lambda { |sync_or_async|
        { "Content-Type" => "application/json",
          "User-Agent" => "keen-gem, v#{Keen::VERSION}, #{sync_or_async}, #{RUBY_VERSION}, #{RUBY_PLATFORM}, #{RUBY_PATCHLEVEL}, #{RUBY_ENGINE}" }
      }
    }

    def beacon_url(event_collection, properties)
      json = MultiJson.encode(properties)
      data = [json].pack("m0").tr("+/", "-_").gsub("\n", "")
      "https://#{api_host}/#{api_version}/projects/#{@project_id}/events/#{event_collection}?api_key=#{@api_key}&data=#{data}"
    end

    def initialize(*args)
      options = args[0]
      unless options.is_a?(Hash)
        # deprecated, pass a hash of options instead
        options = {
          :project_id => args[0],
          :api_key => args[1],
        }.merge(args[2] || {})
      end

      @project_id, @api_key = options.values_at(
        :project_id, :api_key)
    end

    def publish(event_collection, properties)
      check_configuration!
      begin
        response = Keen::HTTP::Sync.new(
          api_host, api_port, api_sync_http_options).post(
            :path => api_path(event_collection),
            :headers => api_headers_with_auth("sync"),
            :body => MultiJson.encode(properties))
      rescue Exception => http_error
        raise HttpError.new("Couldn't connect to Keen IO: #{http_error.message}", http_error)
      end
      process_response(response.code, response.body.chomp)
    end

    def publish_async(event_collection, properties)
      check_configuration!

      deferrable = EventMachine::DefaultDeferrable.new

      http_client = Keen::HTTP::Async.new(api_host, api_port, api_async_http_options)
      http = http_client.post({
        :path => api_path(event_collection),
        :headers => api_headers_with_auth("async"),
        :body => MultiJson.encode(properties)
      })

      if defined?(EM::Synchrony)
        if http.error
          Keen.logger.warn("Couldn't connect to Keen IO: #{http.error}")
          raise HttpError.new("Couldn't connect to Keen IO: #{http.error}")
        else
          process_response(http.response_header.status, http.response.chomp)
        end
      else
        http.callback {
          begin
            response = process_response(http.response_header.status, http.response.chomp)
            deferrable.succeed(response)
          rescue Exception => e
            deferrable.fail(e)
          end
        }
        http.errback {
          Keen.logger.warn("Couldn't connect to Keen IO: #{http.error}")
          deferrable.fail(Error.new("Couldn't connect to Keen IO: #{http.error}"))
        }
        deferrable
      end
    end

    # deprecated
    def add_event(event_collection, properties, options={})
      self.publish(event_collection, properties, options)
    end

    private

    def process_response(status_code, response_body)
      body = MultiJson.decode(response_body)
      case status_code.to_i
      when 200..201
        return body
      when 400
        raise BadRequestError.new(body)
      when 401
        raise AuthenticationError.new(body)
      when 404
        raise NotFoundError.new(body)
      else
        raise HttpError.new(body)
      end
    end

    def api_path(collection)
      "/#{api_version}/projects/#{project_id}/events/#{collection}"
    end

    def api_headers_with_auth(sync_or_async)
      api_headers(sync_or_async).merge("Authorization" => api_key)
    end

    def check_configuration!
      raise ConfigurationError, "Project ID must be set" unless project_id
      raise ConfigurationError, "API Key must be set" unless api_key
    end

    def method_missing(_method, *args, &block)
      if config = CONFIG[_method.to_sym]
        if config.is_a?(Proc)
          config.call(*args)
        else
          config
        end
      else
        super
      end
    end
  end
end
