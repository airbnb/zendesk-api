module Zendesk
  class Main
    attr_accessor :main_url, :format
    attr_reader :response_raw, :response

    def initialize(account, username, password_or_token, options = {})
      @options = options
      if @options[:token]
        @token = password_or_token
      else
        @password = password_or_token
      end
      @account = account
      @username = username      
      if options[:format] && ['xml', 'json'].any?{|f| f == options[:format]}
        @format = options[:format]
      else
        @format = 'xml'
      end
    end

    def main_url
      url_prefix    = @options[:ssl] ? "https://" : "http://"
      url_postfix   = '.zendesk.com/'
      url_postfix   << "api/v#{@options[:api_version]}/" if @options[:api_version]

      url = url_prefix + @account + url_postfix
    end


    def to_format(function_name, input)
      if input.is_a?(String)
        input
      else
        case @format
        when 'xml' then input.to_xml({:root => function_name})
        when 'json' then {function_name => input}.to_json
        end
      end
    end

    def params_list(list)
      params = "?" + list.map do |k, v|
        if v.is_a?(Array)
          v.map do |val|
            "#{k}[]=#{val}"
          end.join("&")
        else
          "#{k}=#{v}"
        end
      end.join("&")
    end
    
    def string_body(body)
      if body.values.first.is_a?(Hash)
        case @format
        when 'xml' then body.values.first.to_xml.strip
        when 'json' then body.values.first.to_json.strip
        end
      elsif body.values.first.is_a?(String)
        body.values.first
      end
    end
    
    def credentials
      if @token
        "#{@username}/token:#{@token}"
      else
        "#{@username}:#{@password}"
      end
    end

    def make_request(end_url, body = {}, options = {})
      options.reverse_merge!({:on_behalf_of => nil})
      
      curl = Curl::Easy.new(main_url + end_url + ".#{@format}")
      curl.userpwd = self.credentials
      
      curl.headers={}
      curl.headers.merge!({"X-On-Behalf-Of" => options[:on_behalf_of]}) if options[:on_behalf_of].present?
      
      curl.headers.merge! "Content-Type" => "application/#{@format}"
      
      if body.empty? or body[:list]
        curl.url = curl.url + params_list(body[:list]) if body[:list]
        curl.perform
      elsif body[:post]
        # curl.headers.merge!({"Content-Type" => "application/xml"})
        curl.http_post 
      elsif body[:create]
        # curl.headers.merge!({"Content-Type" => "application/xml"})
        curl.http_post(string_body(body))
      elsif body[:update]
        # PUT seems badly broken, at least I can't get it to work without always
        # raising an exception about rewinding the data stream
        # curl.http_put(string_body(body))
        curl.headers.merge! "X-Http-Method-Override" => "put"
        curl.http_post(string_body(body))
      elsif body[:destroy]
        curl.http_delete
      end
      
      handle_error Response.new(curl, format)
    end
    
    def handle_error(resp)
      error_message = resp.body if resp.headers.try(:[], "Content-Type") == "text/plain"
      error_message ||= resp.data.is_a?(Hash) && resp.data.try(:[], 'error').to_s
      error = case resp.status
      when 302 # doesn't look like there's a successful case that returns 302, usually mangled request path
        RequestError.new("redirected")
      when 401
        AuthenticationError
      when 404
        error_message == 'RecordNotFound' ? RecordNotFoundError : NotFoundError
      when 400..499
        RequestError
      when 500..599
        ServiceError
      else
        nil
      end
      
      # raise error or return response
      if error
        error = error.new(error_message) if error.is_a?(Class)
        error.response = resp
        raise error
        nil
      else
        resp
      end
    end

    class Response

      attr_reader :status, :body, :headers_raw, :headers, :curl, :url, :data

      def initialize(curl, format)
        @format=format
        @curl = curl
        @url = curl.url
        @status = curl.response_code
        @body = curl.body_str
        @headers_raw = curl.header_str
        parse_headers
        # parse the data coming back
        begin
          @data = case @format
          when 'xml'
            Crack::XML.parse(@body || "")
          when 'json'
            JSON.parse(@body || "")
          end
        rescue
        end 
      end

      def parse_headers
        hs={}
        return hs if headers_raw.nil? or headers_raw==""
        headers_raw.split("\r\n")[1..-1].each do |h|
          m=h.match(/([^:]+):\s?(.*)/)
          next if m.nil? or m[2].nil?
          hs[m[1]]=m[2]
        end
        @headers=hs
      end

    end

    include Zendesk::User
    include Zendesk::UserIdentity
    include Zendesk::Organization
    include Zendesk::Group
    include Zendesk::Ticket
    include Zendesk::Attachment
    include Zendesk::Tag
    include Zendesk::Forum
    include Zendesk::Entry
    include Zendesk::Search
    include Zendesk::Comment
  end
end
