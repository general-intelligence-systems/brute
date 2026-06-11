# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"
require "net/http"
require "fileutils"
require_relative "driver"

module BrowserAgent
  # Browser automation tools, ported from inference-gateway/browser-agent
  # (tools/*.go). Tool names, descriptions, and parameter descriptions are
  # copied verbatim. Browser work is delegated to a Driver (see driver.rb);
  # the Fetch tool talks plain HTTP and needs no browser.
  #
  # Fetch configuration:
  #   FETCH_ALLOWED_DOMAINS  comma-separated whitelist (default "*")
  #   FETCH_MAX_BYTES        response size cap (default 2 MiB)
  #   FETCH_ALLOW_DOWNLOADS  "true" to enable save_path
  #   FETCH_DOWNLOAD_DIR     where save_path files land (default tmp/downloads)
  module Tools
    DEFAULT_TIMEOUT_MS = 30_000

    class BrowserTool < RubyLLM::Tool
      def initialize(driver)
        @driver = driver
      end

      private

        attr_reader :driver
    end

    class NavigateToUrl < BrowserTool
      description "Navigate to a specific URL and wait for the page to fully load"

      param :url, type: "string", desc: "The URL to navigate to", required: true
      param :wait_until, type: "string", desc: "When to consider navigation succeeded (domcontentloaded, load, networkidle)", required: false
      param :timeout, type: "integer", desc: "Maximum navigation timeout in milliseconds", required: false

      def name = "navigate_to_url"

      def execute(url:, wait_until: "load", timeout: DEFAULT_TIMEOUT_MS)
        result = driver.goto(url: url, wait_until: wait_until, timeout_ms: timeout.to_i)
        JSON.generate({ success: true }.merge(result))
      end
    end

    class ClickElement < BrowserTool
      description "Click on an element identified by selector, text, or other locator strategies"

      param :selector, type: "string", desc: "CSS selector, XPath, or text to identify the element", required: true
      param :button, type: "string", desc: "Mouse button to use (left, right, middle)", required: false
      param :click_count, type: "integer", desc: "Number of times to click", required: false
      param :force, type: "boolean", desc: "Force click even if element is not visible or actionable (skips the pre-click visibility wait)", required: false
      param :timeout, type: "integer", desc: "Maximum time to wait for element in milliseconds", required: false

      def name = "click_element"

      def execute(selector:, button: "left", click_count: 1, force: false, timeout: DEFAULT_TIMEOUT_MS)
        result = driver.click(selector: selector, button: button, click_count: click_count.to_i,
                              force: force, timeout_ms: timeout.to_i)
        JSON.generate({ success: true }.merge(result))
      end
    end

    class FillForm < BrowserTool
      params({
        type: "object",
        properties: {
          fields: {
            type:        "array",
            description: "List of form fields to fill",
            items: {
              type:     "object",
              required: %w[selector value],
              properties: {
                selector: { type: "string", description: "Selector for the form field" },
                value:    { type: "string", description: "Value to fill in the field. For select with multiple=true, use comma-separated values" },
                type:     { type: "string", description: "Type of input: text, textarea, password, select, checkbox, radio, file", default: "text" },
                multiple: { type: "boolean", description: "For select fields only: whether this is a multi-select dropdown", default: false },
              },
            },
          },
          submit:          { type: "boolean", description: "Whether to submit the form after filling", default: false },
          submit_selector: { type: "string", description: "Selector for the submit button" },
        },
        required: %w[fields],
      })

      description "Fill form fields with provided data, handling various input types"

      def name = "fill_form"

      def execute(fields:, submit: false, submit_selector: nil)
        result = driver.fill(fields: fields, submit: submit, submit_selector: submit_selector)
        JSON.generate({ success: true }.merge(result))
      end
    end

    class ExecuteScript < BrowserTool
      description "Execute custom JavaScript inside the current page via Playwright's " \
                  "page.evaluate(). The script runs in the browser context, NOT in Node.js: " \
                  "globals like window, document, navigator, fetch and localStorage are " \
                  "available; Node.js built-ins (require, process, __dirname, __filename, " \
                  "fs, path, os, http, https, child_process, etc.) are NOT available and " \
                  "calls to them will be rejected. Use browser/DOM APIs only. The script " \
                  "body is automatically wrapped in an IIFE, so a top-level `return` is " \
                  "valid. Set async=true if the body uses `await`."

      params({
        type: "object",
        properties: {
          script:       { type: "string", description: "JavaScript code to execute in the browser (Playwright page.evaluate context). Use DOM/Web APIs only - Node.js built-ins are unavailable." },
          args:         { type: "array", items: {}, description: "Arguments to pass to the script (will be available as arguments[0], arguments[1], etc.)", default: [] },
          return_value: { type: "boolean", description: "Whether to return the script execution result", default: true },
          timeout:      { type: "integer", description: "Maximum script execution timeout in milliseconds", default: 30_000 },
          async:        { type: "boolean", description: "Whether the script contains async operations (will wrap in async function)", default: false },
        },
        required: %w[script],
      })

      def name = "execute_script"

      def execute(script:, args: [], return_value: true, timeout: 30_000, async: false)
        result = driver.evaluate(script: script, args: args, async: async, timeout_ms: timeout.to_i)
        JSON.generate(success: true, result: return_value ? result : nil)
      end
    end

    class ExtractData < BrowserTool
      description "Extract data from the page using selectors and return structured information"

      params({
        type: "object",
        properties: {
          extractors: {
            type:        "array",
            description: "List of data extractors to run",
            items: {
              type:     "object",
              required: %w[name selector],
              properties: {
                name:      { type: "string", description: "Name for the extracted data field" },
                selector:  { type: "string", description: "CSS selector or XPath to extract data from" },
                attribute: { type: "string", description: "Attribute to extract (text, href, src, etc.)", default: "text" },
                multiple:  { type: "boolean", description: "Extract all matching elements or just the first", default: false },
              },
            },
          },
          format: { type: "string", description: "Output format (json, csv, text)", default: "json" },
        },
        required: %w[extractors],
      })

      def name = "extract_data"

      def execute(extractors:, format: "json")
        data = driver.extract(extractors: extractors)
        body =
          case format
          when "csv"
            ([data.keys.join(",")] + [data.values.map { |v| Array(v).join(";") }.join(",")]).join("\n")
          when "text"
            data.map { |k, v| "#{k}: #{Array(v).join(", ")}" }.join("\n")
          else
            JSON.generate(data)
          end
        JSON.generate(success: true, format: format, data: body)
      end
    end

    class TakeScreenshot < BrowserTool
      description "Capture a screenshot of the current page or specific element with deterministic file naming"

      param :full_page, type: "boolean", desc: "Capture the entire scrollable page", required: false
      param :selector, type: "string", desc: "Optional selector to screenshot specific element", required: false
      param :type, type: "string", desc: "Image format (png, jpeg)", required: false
      param :quality, type: "integer", desc: "Quality for jpeg images (0-100)", required: false

      def name = "take_screenshot"

      def execute(full_page: false, selector: nil, type: "png", quality: 80)
        dir = ENV.fetch("SCREENSHOT_DIR", "tmp/screenshots")
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "screenshot-#{Time.now.strftime("%Y%m%d-%H%M%S")}-#{format("%04x", rand(0xffff))}.#{type}")

        driver.screenshot(path: path, full_page: full_page, selector: selector, format: type, quality: quality.to_i)
        JSON.generate(success: true, path: path, full_page: full_page, type: type)
      end
    end

    class WaitForCondition < BrowserTool
      description "Wait for specific conditions before proceeding with automation"

      param :condition, type: "string", desc: "Type of condition (selector, navigation, function, timeout, networkidle)", required: true
      param :selector, type: "string", desc: "Selector to wait for if condition is 'selector'", required: false
      param :state, type: "string", desc: "State to wait for (visible, hidden, attached, detached)", required: false
      param :custom_function, type: "string", desc: "Custom JavaScript function to evaluate for 'function' condition", required: false
      param :timeout, type: "integer", desc: "Maximum time to wait in milliseconds", required: false

      def name = "wait_for_condition"

      def execute(condition:, selector: nil, state: "visible", custom_function: nil, timeout: DEFAULT_TIMEOUT_MS)
        result = driver.wait_for(condition: condition, selector: selector, state: state,
                                 custom_function: custom_function, timeout_ms: timeout.to_i)
        JSON.generate({ success: true }.merge(result))
      end
    end

    class HandleAuthentication < BrowserTool
      description "NOT YET IMPLEMENTED: This tool currently returns an error explaining that authentication " \
                  "is not wired through. For basic auth, configure HTTP credentials at the browser context " \
                  "level. For form login, compose navigate_to_url + fill_form + click_element. For OAuth, " \
                  "run the flow manually with the above primitives."

      VALID_AUTH_TYPES = %w[basic form oauth].freeze

      param :type, type: "string", desc: "Authentication type (basic, form, oauth)", required: true
      param :login_url, type: "string", desc: "URL of the login page for form authentication", required: false
      param :username, type: "string", desc: "Username or email for authentication", required: false
      param :password, type: "string", desc: "Password for authentication", required: false
      param :username_selector, type: "string", desc: "Selector for username field in form authentication", required: false
      param :password_selector, type: "string", desc: "Selector for password field in form authentication", required: false
      param :submit_selector, type: "string", desc: "Selector for submit button in form authentication", required: false

      def name = "handle_authentication"

      def execute(type:, **_unused)
        unless VALID_AUTH_TYPES.include?(type)
          raise "invalid auth type: #{type}. Must be one of: #{VALID_AUTH_TYPES}"
        end

        raise "handle_authentication is not yet implemented (auth_type=#{type}). " \
              "For basic auth, configure HTTP credentials at the browser context level. " \
              "For form login, compose navigate_to_url + fill_form + click_element instead. " \
              "For OAuth, drive the flow manually with the same primitives"
      end
    end

    class Fetch < RubyLLM::Tool
      description "Fetch a URL over HTTP(S). Subject to an allowed-domains whitelist and a max-bytes cap; " \
                  "can optionally save the response body to a file inside the configured download_dir."

      params({
        type: "object",
        additionalProperties: false,
        properties: {
          url:       { type: "string", description: "The absolute http(s) URL to fetch." },
          method:    { type: "string", description: "HTTP method. Only GET and HEAD are supported.", enum: %w[GET HEAD] },
          save_path: { type: "string", description: "Optional filename (or relative path) inside the configured download_dir to write the body to. Requires allow_downloads=true. Absolute paths and parent-dir traversal are rejected." },
          headers:   { type: "object", description: "Optional extra request headers.", additionalProperties: { type: "string" } },
        },
        required: %w[url],
      })

      def name = "Fetch"

      def execute(url:, method: "GET", save_path: nil, headers: nil)
        uri = URI(url)
        raise "only http(s) URLs are supported" unless uri.is_a?(URI::HTTP)
        raise "domain not allowed: #{uri.host}" unless allowed_domain?(uri.host)
        raise "only GET and HEAD are supported" unless %w[GET HEAD].include?(method)

        request = Net::HTTP.const_get(method.capitalize).new(uri)
        (headers || {}).each { |key, value| request[key.to_s] = value }

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
        body = (response.body || "").byteslice(0, max_bytes)

        if save_path
          raise "downloads are disabled - set FETCH_ALLOW_DOWNLOADS=true" unless ENV["FETCH_ALLOW_DOWNLOADS"] == "true"
          raise "absolute paths and parent-dir traversal are rejected" if save_path.start_with?("/") || save_path.split("/").include?("..")

          target = File.join(ENV.fetch("FETCH_DOWNLOAD_DIR", "tmp/downloads"), save_path)
          FileUtils.mkdir_p(File.dirname(target))
          File.binwrite(target, body)
          return JSON.generate(success: true, status: response.code.to_i, saved_to: target, bytes: body.bytesize)
        end

        JSON.generate(success: true, status: response.code.to_i, content_type: response["Content-Type"], body: body)
      end

      private

        def allowed_domain?(host)
          allowed = ENV.fetch("FETCH_ALLOWED_DOMAINS", "*").split(",").map(&:strip)
          allowed.include?("*") || allowed.any? { |domain| host == domain || host.end_with?(".#{domain}") }
        end

        def max_bytes
          ENV.fetch("FETCH_MAX_BYTES", 2 * 1024 * 1024).to_i
        end
    end

    # Instantiate the browser tools against the given driver (Fetch needs
    # no browser). The upstream Read/Write/Edit file tools map to brute's
    # own FSRead/FSWrite/FSPatch — add those in the agent's tool list.
    def self.build(driver)
      [
        NavigateToUrl.new(driver),
        ClickElement.new(driver),
        FillForm.new(driver),
        ExecuteScript.new(driver),
        ExtractData.new(driver),
        TakeScreenshot.new(driver),
        WaitForCondition.new(driver),
        HandleAuthentication.new(driver),
        Fetch.new,
      ]
    end
  end
end
