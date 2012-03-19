require 'spec_helper'
require 'omniauth-riodatamine'
require 'openssl'
require 'base64'

describe OmniAuth::Strategies::Riodatamine do
  before :each do
    @request = double('Request')
    @request.stub(:params) { {} }
    @request.stub(:cookies) { {} }
    @request.stub(:env) { {} }

    @client_id = '123'
    @client_secret = '53cr3tz'
  end

  subject do
    args = [@client_id, @client_secret, @options].compact
    OmniAuth::Strategies::Riodatamine.new(nil, *args).tap do |strategy|
      strategy.stub(:request) { @request }
    end
  end

  it_should_behave_like 'an oauth2 strategy'

  describe '#client' do
    it 'has correct Riodatamine site' do
      subject.client.site.should eq('http://api.riodatamine.com.br')
    end

    it 'has correct authorize url' do
      subject.client.options[:authorize_url].should eq('/oauth/authorize')
    end

    it 'has correct token url' do
      subject.client.options[:token_url].should eq('/oauth/access_token')
    end
  end

  describe '#callback_url' do
    it "returns the default callback url" do
      url_base = 'http://auth.request.com'
      @request.stub(:url) { "#{url_base}/some/page" }
      subject.stub(:script_name) { '' } # as not to depend on Rack env
      subject.callback_url.should eq("#{url_base}/auth/riodatamine/callback")
    end

    it "returns path from callback_path option" do
      @options = { :callback_path => "/auth/riodatamine/done"}
      url_base = 'http://auth.request.com'
      @request.stub(:url) { "#{url_base}/page/path" }
      subject.stub(:script_name) { '' } # as not to depend on Rack env
      subject.callback_url.should eq("#{url_base}/auth/riodatamine/done")
    end

    it "returns url from callback_url option" do
      url = 'https://auth.myapp.com/auth/riodatamine/callback'
      @options = { :callback_url => url }
      subject.callback_url.should eq(url)
    end
  end

  describe '#credentials' do
    before :each do
      @access_token = double('OAuth2::AccessToken')
      @access_token.stub(:token)
      @access_token.stub(:expires?)
      @access_token.stub(:expires_at)
      @access_token.stub(:refresh_token)
      subject.stub(:access_token) { @access_token }
    end

    it 'returns a Hash' do
      subject.credentials.should be_a(Hash)
    end

    it 'returns the token' do
      @access_token.stub(:token) { '123' }
      subject.credentials['token'].should eq('123')
    end

    it 'returns the expiry status' do
      @access_token.stub(:expires?) { true }
      subject.credentials['expires'].should eq(true)

      @access_token.stub(:expires?) { false }
      subject.credentials['expires'].should eq(false)
    end

    it 'returns the refresh token and expiry time when expiring' do
      ten_mins_from_now = (Time.now + 600).to_i
      @access_token.stub(:expires?) { true }
      @access_token.stub(:refresh_token) { '321' }
      @access_token.stub(:expires_at) { ten_mins_from_now }
      subject.credentials['refresh_token'].should eq('321')
      subject.credentials['expires_at'].should eq(ten_mins_from_now)
    end

    it 'does not return the refresh token when it is nil and expiring' do
      @access_token.stub(:expires?) { true }
      @access_token.stub(:refresh_token) { nil }
      subject.credentials['refresh_token'].should be_nil
      subject.credentials.should_not have_key('refresh_token')
    end

    it 'does not return the refresh token when not expiring' do
      @access_token.stub(:expires?) { false }
      @access_token.stub(:refresh_token) { 'XXX' }
      subject.credentials['refresh_token'].should be_nil
      subject.credentials.should_not have_key('refresh_token')
    end
  end

  describe '#signed_request' do
    context 'cookie/param not present' do
      it 'is nil' do
        subject.send(:signed_request).should be_nil
      end
    end

  end

  describe '#build_access_token' do
    describe 'params contain a signed request with an access token' do
      before do
        @payload = {
          'algorithm' => 'HMAC-SHA256',
          'oauth_token' => 'm4c0d3z'
        }
        @raw_signed_request = signed_request(@payload, @client_secret)
        @request.stub(:params) do
          { "signed_request" => @raw_signed_request }
        end

        subject.stub(:callback_url) { '/' }
      end

      it 'returns a new access token from the signed request' do
        result = subject.build_access_token
        result.should be_an_instance_of(::OAuth2::AccessToken)
        result.token.should eq(@payload['oauth_token'])
      end
    end
  end

private

  def signed_request(payload, secret)
    encoded_payload = base64_encode_url(MultiJson.encode(payload))
    encoded_signature = base64_encode_url(signature(encoded_payload, secret))
    [encoded_signature, encoded_payload].join('.')
  end

  def base64_encode_url(value)
    Base64.encode64(value).tr('+/', '-_').gsub(/\n/, '')
  end

  def signature(payload, secret, algorithm = OpenSSL::Digest::SHA256.new)
    OpenSSL::HMAC.digest(algorithm, secret, payload)
  end
end
