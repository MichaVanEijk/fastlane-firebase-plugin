module Fastlane
  module Firebase
    class Api 
      class LoginError < StandardError 
      end

      class BadRequestError < StandardError
        attr_reader :code
        def initialize(msg, code)
          @code = code
          super(msg)
        end
      end

      require 'mechanize'
      require 'digest/sha1'
      require 'json'
      require 'cgi'

      def initialize(email, password)
        @agent = Mechanize.new
        @base_url = "https://console.firebase.google.com"
        @sdk_url = "https://mobilesdk-pa.clients6.google.com/"
        @firebase_url = "https://firebase.clients6.google.com"
        @login_url = "https://accounts.google.com/ServiceLogin"
        @apikey_url = "https://apikeys.clients6.google.com/"

        login(email, password)
      end

      def login(email, password)
        UI.message "Logging in to Google account #{email}"

        # Load cookie from ENV into file if is set
        if !ENV["FIREBASE_COOKIE"].nil? then
          File.open('.cookies.yml', 'w') { |file| file.write(ENV["FIREBASE_COOKIE"]) }
        end

        # Try to load cookie from file
        begin
          @agent.cookie_jar.load '.cookies.yml'
          UI.message "Cookies found!"

          page = @agent.get(@base_url)
        rescue
          UI.message "Cookies not found, trying to login"

          page = @agent.get("#{@login_url}?passive=1209600&osid=1&continue=#{@base_url}/&followup=#{@base_url}/")

          #First step - email
          google_form = page.form()
          google_form.Email = email

          #Send
          page = @agent.submit(google_form, google_form.buttons.first)

          #Second step - password or captcha
          google_form = page.form()
          begin
            google_form.Passwd = password
          rescue
            page = captcha_challenge(page, password)
          end

          #Send
          page = @agent.submit(google_form, google_form.buttons.first)
        end

        while page do
          if extract_api_key(page) then
            UI.success "Successfuly logged in"
            return true
          else

            if error = page.at("#errormsg_0_Passwd") then
              message = error.text.strip
            elsif page.xpath("//div[@class='captcha-img']").count > 0 then
              page = captcha_challenge(page, password)
              next
            elsif page.form.action.include? "/signin/challenge" then
              page = signin_challenge(page, password)
              next
            else 
              message = "Unknown error"
            end
            raise LoginError, "Login failed: #{message}"
          end 

        end
      end

      def extract_api_key(page) 
        #Find api key in javascript
        match = page.search("script").text.scan(/\\x22api-key\\x22:\\x22(.*?)\\x22/)
        if match.count == 1 then
          @api_key = match[0][0]
          @authorization_headers = create_authorization_headers()
          return true
        end

        return false
      end

      def captcha_challenge(page, password)
        if UI.confirm "To proceed you need to fill in captcha. Do you want to download captcha image?" then
          img_src = page.images.find { |image| image.alt == 'Visual verification' }.uri
          image = @agent.get(img_src)
          if image != nil then
            UI.success "Captcha image downloaded"
          else 
            UI.crash! "Failed to download captcha image"
          end

          file = Tempfile.new(["firebase_captcha_image", ".jpg"])
          path = file.path 

          image.save!(path)

          UI.success "Captcha image saved at #{path}"

          if UI.confirm "Preview image?" then 
            if system("qlmanage -p #{path} >& /dev/null &") != true && system("open #{path} 2> /dev/null") != true then
              UI.error("Unable to find program to preview the image, open it manually")
            end
          end

          captcha = UI.input "Enter captcha (case insensitive):"

          captcha_form = page.form()

          captcha_form['identifier-captcha-input'] = captcha

          page = @agent.submit(captcha_form, captcha_form.buttons.first)
          return page
        else 
          return nil
        end

      end

      def signin_challenge(page, password)
        UI.header "Sign-in challenge"

        form_id = "challenge"
        form = page.form_with(:id => form_id)
        type = (form["challengeType"] || "-1").to_i

        # Two factor verification SMS
        if type == 9 || type == 6 then
          div = page.at("##{form_id} div")
          if div != nil then 
            UI.important div.xpath("div[1]").text
            UI.important div.xpath("div[2]").text
          end

          prefix = type == 9 ? " G-" : ""
          code = UI.input "Enter code#{prefix}:"
          form.Pin = code
          page = @agent.submit(form, form.buttons.first)
          return page
        elsif type == 4 then 
          UI.user_error! "Google prompt is not supported as a two-step verification"
        elsif type == 1 then
          form = page.forms.first
          form.Passwd = password
          return @agent.submit(form, form.buttons.first)
        elsif type == 39 then
          UI.confirm "Accept prompt on device"
          form = page.forms.first
          return @agent.submit(form, form.buttons.first)
        else
          html = page.at("##{form_id}").to_html
          UI.user_error! "Unknown challenge type \n\n#{html}"
        end

        return nil
      end

      def generate_sapisid_hash(time, sapisid, origin) 
        to_hash = time.to_s + " " + sapisid + " " + origin.to_s

        hash = Digest::SHA1.hexdigest(to_hash)
        sapisid_hash = time.to_s + "_" + hash

        sapisid_hash
      end

      def create_authorization_headers 
        @agent.cookie_jar.save_as '.cookies.yml', :session => true, :format => :yaml
        cookie = @agent.cookie_jar.jar["google.com"]["/"]["SAPISID"]
        sapisid = cookie.value
        origin = @base_url
        time = Time.now.to_i

        sapisid_hash = generate_sapisid_hash(time, sapisid, origin)

        cookies = @agent.cookie_jar.jar["google.com"]["/"].merge(@agent.cookie_jar.jar["console.firebase.google.com"]["/"])
        cookie_header = cookies.map { |el, cookie| "#{el}=#{cookie.value}" }.join(";")

        sapisid_hash = generate_sapisid_hash(time, sapisid, origin)
        sapisid_header = "SAPISIDHASH #{sapisid_hash}"

        json_headers = {
          'Authorization' => sapisid_header,
          'Cookie' => cookie_header,
          'X-Origin' => origin
        }

        json_headers
      end

      def apikey_request_json(path, method = :get, parameters = Hash.new, headers = Hash.new, query = '')
        begin
          if method == :get then
            parameters["key"] = @api_key
            page = @agent.get("#{@apikey_url}#{path}", parameters, nil, headers.merge(@authorization_headers))
          elsif method == :post then
            headers['Content-Type'] = 'application/json'
            puts "#{@apikey_url}#{path}?key=#{@api_key}"
            puts parameters.to_json
            page = @agent.post("#{@apikey_url}#{path}?key=#{@api_key}", parameters.to_json, headers.merge(@authorization_headers))
          elsif method == :patch then
            headers['Content-Type'] = 'application/json'
            page = @agent.request_with_entity(
              'patch', "#{@apikey_url}#{path}?key=#{@api_key}&#{query}", parameters.to_json, headers.merge(@authorization_headers)
            )
          elsif method == :delete then
            page = @agent.delete("#{@apikey_url}#{path}?key=#{@api_key}", parameters, headers.merge(@authorization_headers))
          end

          JSON.parse(page.body)

        rescue Mechanize::ResponseCodeError => e
          code = e.response_code.to_i
          if code >= 400 && code < 500 then
            if body = JSON.parse(e.page.body) then
              raise BadRequestError.new(body["error"]["message"], code)
            end
          end
          UI.crash! e.page.body
        end
      end

      def request_json(path, method = :get, parameters = Hash.new, headers = Hash.new)
        begin
          if method == :get then
            parameters["key"] = @api_key
            page = @agent.get("#{@sdk_url}#{path}", parameters, nil, headers.merge(@authorization_headers))
          elsif method == :post then
            headers['Content-Type'] = 'application/json'
            page = @agent.post("#{@sdk_url}#{path}?key=#{@api_key}", parameters.to_json, headers.merge(@authorization_headers))
          elsif method == :delete then
            page = @agent.delete("#{@sdk_url}#{path}?key=#{@api_key}", parameters, headers.merge(@authorization_headers))
          end

          JSON.parse(page.body)

        rescue Mechanize::ResponseCodeError => e
          code = e.response_code.to_i
          if code >= 400 && code < 500 then
            if body = JSON.parse(e.page.body) then
              raise BadRequestError.new(body["error"]["message"], code)
            end
          end
          UI.crash! e.page.body
        end
      end

      def project_list
        UI.message "Retrieving project list"
        json = request_json("v1/projects")
        projects = json["project"] || []
        UI.success "Found #{projects.count} projects"
        projects
      end

      def add_client(project_number, type, bundle_id, app_name, ios_appstore_id )
        parameters = {
          "requestHeader" => { },
          "displayName" => app_name || ""
        }

        case type
        when :ios
          parameters["iosData"] = {
            "bundleId" => bundle_id,
            "iosAppStoreId" => ios_appstore_id || ""
          }
        when :android
          parameters["androidData"] = {
            "packageName" => bundle_id,
            "androidCertificateHash" => []
          }
        end

        json = request_json("v1/projects/#{project_number}/clients", :post, parameters)
        if client = json["client"] then
          UI.success "Successfuly added client #{bundle_id}"
          client
        else
          UI.error "Client could not be added"
        end
      end

      def delete_client(project_number, client_id)
        json = request_json("v1/projects/#{project_number}/clients/#{client_id}", :delete)
      end

      def upload_certificate(project_number, client_id, type, certificate_value, certificate_password)

        prefix = type == :development ? "debug" : "prod"

        parameters = {
          "#{prefix}ApnsCertificate" => { 
            "certificateValue" => certificate_value,
            "apnsPassword" => certificate_password 
          }
        }

        json = request_json("v1/projects/#{project_number}/clients/#{client_id}:setApnsCertificate", :post, parameters)
      end

      def upload_p8_certificate(project_number, client_id, type, certificate_value, key_code)

        parameters = {
          "keyId" => key_code,
          "privateKey" => certificate_value 
        }

        json = request_json("v1/projects/#{project_number}/clients/#{client_id}:setApnsAuthKey", :post, parameters)
      end

      def download_config_file(project_number, client_id, mobilesdk_app_id)
        code = (client_id.start_with? "ios") ? "iosApps/#{mobilesdk_app_id}" : "androidApps/#{mobilesdk_app_id}"
        url = @firebase_url + "/v1beta1/projects/#{project_number}/#{code}/config"
        UI.message "Downloading config file"
        begin
          config = @agent.get(url, { key: @api_key }, nil, @authorization_headers)
          JSON.parse(config.body)
        rescue Mechanize::ResponseCodeError => e
          UI.crash! e.page.body
        end
      end

      def add_team(project_number, bundle_id, team_id)
        parameters = {
          "iosTeamId" => team_id
        }

        json = request_json("v1/projects/#{project_number}/clients/ios:#{bundle_id}:setTeamId", :post, parameters)
      end

      def add_android_certificate(project_number, bundle_id, sha256)
        parameters = {
          "requestHeader" => { "clientVersion" => "FIREBASE" },
          "projectNumber" => project_number,
          "clientId" => "android:#{bundle_id}",
          "androidCertificate" => {
            "androidSha256Hash" => sha256
          }
        }

        json = request_json("v1/projects/#{project_number}/clients/android:#{bundle_id}:addAndroidCertificate", :post, parameters)
      end

      def add_apple_store_id(project_number, bundle_id, store_id)
        parameters = {
          "requestHeader" => { "clientVersion" => "FIREBASE" },
          "projectNumber" => project_number,
          "clientId" => "android:#{bundle_id}",
          iosAppStoreId: store_id
        }

        json = request_json("v1/projects/#{project_number}/clients/ios:#{bundle_id}:setAppStoreId", :post, parameters)
      end

      def get_apikey(project_number, api_key)
        json = apikey_request_json("v1/projects/#{project_number}/apiKeys/#{api_key}", :get)
      end

      def update_apikey(project_number, api_key, update_mask, payload)
        json = apikey_request_json(
          "v1/projects/#{project_number}/apiKeys/#{api_key}", :patch, payload, Hash.new, "updateMask=#{update_mask}"
        )
      end

      def get_server_key(project_number) 
        parameters = {}
        json = request_json("v1/projects/#{project_number}:getIidTokens", :post, parameters)
      end
    end
  end
end
