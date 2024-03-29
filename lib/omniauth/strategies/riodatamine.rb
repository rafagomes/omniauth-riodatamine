require 'omniauth/strategies/oauth2'
require 'base64'
require 'openssl'
require 'rack/utils'

module OmniAuth
  module Strategies
    class Riodatamine < OmniAuth::Strategies::OAuth2
      class NoAuthorizationCodeError < StandardError; end

      DEFAULT_SCOPE = 'email,offline_access'

      option :client_options, {
        :site => 'http://api.riodatamine.com.br',
        :token_url => '/oauth/access_token'
      }

      option :token_params, {
        :parse => :query
      }

      option :access_token_options, {
        :header_format => 'OAuth %s',
        :param_name => 'access_token'
      }

      option :authorize_options, [:scope, :display]

      uid { raw_info['id'] }

      info do
        prune!({
          'name' => raw_info['name']
        })
      end

      credentials do
        prune!({
          'expires' => access_token.expires?,
          'expires_at' => access_token.expires_at
        })
      end

      extra do
        prune!({
          'raw_info' => raw_info
        })
      end

      def raw_info
        @raw_info ||= access_token.get('/me').parsed
      end

      def build_access_token
        if signed_request_contains_access_token?
          hash = signed_request.clone
          ::OAuth2::AccessToken.new(
            client,
            hash.delete('oauth_token'),
            hash.merge!(access_token_options)
          )
        else
          with_authorization_code! { super }.tap do |token|
            token.options.merge!(access_token_options)
          end
        end
      end

      def request_phase
        if signed_request_contains_access_token?
          # if we already have an access token, we can just hit the
          # callback URL directly and pass the signed request along
          params = { :signed_request => raw_signed_request }
          params[:state] = request.params['state'] if request.params['state']
          query = Rack::Utils.build_query(params)

          url = callback_url
          url << "?" unless url.match(/\?/)
          url << "&" unless url.match(/[\&\?]$/)
          url << query

          redirect url
        else
          super
        end
      end

      # NOTE if we're using code from the signed request
      # then FB sets the redirect_uri to '' during the authorize
      # phase + it must match during the access_token phase:
      # https://github.com/facebook/php-sdk/blob/master/src/base_facebook.php#L348
      def callback_url
        if @authorization_code_from_signed_request
          ''
        else
          options[:callback_url] || super
        end
      end

      def access_token_options
        options.access_token_options.inject({}) { |h,(k,v)| h[k.to_sym] = v; h }
      end

      ##
      # You can pass +display+, +state+ or +scope+ params to the auth request, if
      # you need to set them dynamically. You can also set these options
      # in the OmniAuth config :authorize_params option.
      #
      # /auth/facebook?display=popup&state=ABC
      #
      def authorize_params
        super.tap do |params|
          %w[display state scope].each { |v| params[v.to_sym] = request.params[v] if request.params[v] }
          params[:scope] ||= DEFAULT_SCOPE
        end
      end

      ##
      # Parse signed request in order, from:
      #
      # 1. the request 'signed_request' param (server-side flow from canvas pages) or
      # 2. a cookie (client-side flow via JS SDK)
      #
      def signed_request
        @signed_request ||= raw_signed_request &&
          parse_signed_request(raw_signed_request)
      end

      private

      def raw_signed_request
        request.params['signed_request'] ||
        request.cookies["fbsr_#{client.id}"]
      end

      def signed_request_contains_access_token?
        signed_request &&
        signed_request['oauth_token']
      end

      ##
      # Picks the authorization code in order, from:
      #
      # 1. the request 'code' param (manual callback from standard server-side flow)
      # 2. a signed request (see #signed_request for more)
      #
      def with_authorization_code!
        if request.params.key?('code')
          yield
        elsif code_from_signed_request = signed_request && signed_request['code']
          request.params['code'] = code_from_signed_request
          @authorization_code_from_signed_request = true
          begin
            yield
          ensure
            request.params.delete('code')
            @authorization_code_from_signed_request = false
          end
        else
          raise NoAuthorizationCodeError, 'must pass either a `code` parameter or a signed request (via `signed_request` parameter or a `fbsr_XXX` cookie)'
        end
      end

      def prune!(hash)
        hash.delete_if do |_, value|
          prune!(value) if value.is_a?(Hash)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
      end

      def parse_signed_request(value)
        signature, encoded_payload = value.split('.')

        decoded_hex_signature = base64_decode_url(signature)
        decoded_payload = MultiJson.decode(base64_decode_url(encoded_payload))

        unless decoded_payload['algorithm'] == 'HMAC-SHA256'
          raise NotImplementedError, "unkown algorithm: #{decoded_payload['algorithm']}"
        end

        if valid_signature?(client.secret, decoded_hex_signature, encoded_payload)
          decoded_payload
        end
      end

      def valid_signature?(secret, signature, payload, algorithm = OpenSSL::Digest::SHA256.new)
        OpenSSL::HMAC.digest(algorithm, secret, payload) == signature
      end

      def base64_decode_url(value)
        value += '=' * (4 - value.size.modulo(4))
        Base64.decode64(value.tr('-_', '+/'))
      end
    end
  end
end
