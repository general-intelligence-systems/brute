# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"
require_relative "../driver"

module BrowserAgent
  module Drivers
    # Chrome-over-CDP driver backed by the ferrum gem — the reference
    # Driver implementation (upstream uses Playwright). Install ferrum via
    # the optional group:
    #
    #   bundle config set --local with browser && bundle install
    #
    # HEADLESS=false shows the browser window.
    class Ferrum < Driver
      def initialize
        require "ferrum"
      rescue LoadError
        raise "BrowserAgent::Drivers::Ferrum needs the 'ferrum' gem. Install it with " \
              "`bundle config set --local with browser && bundle install` " \
              "(and make sure Chrome/Chromium is available)."
      end

      def browser
        @browser ||= ::Ferrum::Browser.new(
          headless: ENV.fetch("HEADLESS", "true") != "false",
          timeout:  60,
        )
      end

      def goto(url:, wait_until: "load", timeout_ms: 30_000)
        browser.go_to(url)
        browser.network.wait_for_idle(timeout: timeout_ms / 1000.0) if wait_until == "networkidle"
        { url: browser.current_url, title: browser.evaluate("document.title") }
      end

      def click(selector:, button: "left", click_count: 1, force: false, timeout_ms: 30_000)
        node = wait_for_node(selector, timeout_ms: timeout_ms, visible: !force)
        node.click(button: button.to_sym, count: click_count.to_i)
        { selector: selector, clicked: true }
      end

      def fill(fields:, submit: false, submit_selector: nil)
        filled = fields.map do |field|
          field = field.transform_keys(&:to_s)
          selector, value = field.values_at("selector", "value")
          type = field.fetch("type", "text")

          case type
          when "checkbox", "radio"
            set_checked(selector, value)
          when "select"
            select_options(selector, value, multiple: field["multiple"])
          when "file"
            wait_for_node(selector, visible: false).select_file(value)
          else # text, textarea, password
            node = wait_for_node(selector, visible: false)
            node.focus
            evaluate_on(node, "this.value = ''")
            node.type(value)
          end
          { selector: selector, type: type }
        end

        browser.at_css(submit_selector || "form [type=submit], form button")&.click if submit
        { filled: filled, submitted: !!submit }
      end

      def evaluate(script:, args: [], async: false, timeout_ms: 30_000)
        wrapped = "(#{async ? "async " : ""}function() { #{script} }).apply(null, #{JSON.generate(args)})"
        return browser.evaluate(wrapped) unless async

        browser.evaluate(<<~JS)
          (function() {
            window.__brute_done = false; window.__brute_result = undefined; window.__brute_error = undefined;
            #{wrapped}
              .then(function(r) { window.__brute_result = r; window.__brute_done = true; })
              .catch(function(e) { window.__brute_error = String(e); window.__brute_done = true; });
          })()
        JS
        poll(timeout_ms, "script did not finish") { browser.evaluate("window.__brute_done") }
        error = browser.evaluate("window.__brute_error")
        raise "script failed: #{error}" if error

        browser.evaluate("window.__brute_result")
      end

      def extract(extractors:)
        extractors.each_with_object({}) do |extractor, results|
          extractor = extractor.transform_keys(&:to_s)
          name, selector = extractor.values_at("name", "selector")
          attribute = extractor.fetch("attribute", "text")
          js_value  = attribute == "text" ? "el.textContent.trim()" : "el.getAttribute(#{JSON.generate(attribute)})"

          results[name] = browser.evaluate(<<~JS)
            (function() {
              var els = Array.from(document.querySelectorAll(#{JSON.generate(selector)}));
              var values = els.map(function(el) { return #{js_value}; });
              return #{extractor["multiple"] ? "values" : "values[0]"};
            })()
          JS
        end
      end

      def screenshot(path:, full_page: false, selector: nil, format: "png", quality: 80)
        options = { path: path, full: full_page, format: format }
        options[:quality]  = quality.to_i if format == "jpeg"
        options[:selector] = selector if selector
        browser.screenshot(**options)
        path
      end

      def wait_for(condition:, selector: nil, state: "visible", custom_function: nil, timeout_ms: 30_000)
        case condition
        when "selector"
          raise "selector is required for the 'selector' condition" unless selector

          poll(timeout_ms, "selector #{selector.inspect} never became #{state}") { selector_state?(selector, state) }
        when "navigation", "networkidle"
          browser.network.wait_for_idle(timeout: timeout_ms / 1000.0)
        when "function"
          raise "custom_function is required for the 'function' condition" unless custom_function

          poll(timeout_ms, "custom function never returned true") { browser.evaluate("(#{custom_function})()") }
        when "timeout"
          sleep(timeout_ms / 1000.0)
        else
          raise "unknown condition: #{condition}. Must be one of: selector, navigation, function, timeout, networkidle"
        end
        { condition: condition, met: true }
      end

      def quit
        @browser&.quit
        @browser = nil
      end

      private

        def find_node(selector)
          selector.start_with?("/", "(") ? browser.at_xpath(selector) : browser.at_css(selector)
        end

        def wait_for_node(selector, timeout_ms: 30_000, visible: true)
          node = nil
          poll(timeout_ms, "element #{selector.inspect} not found#{" or not visible" if visible}") do
            node = find_node(selector)
            node && (!visible || node_visible?(node))
          end
          node
        end

        def evaluate_on(node, expression)
          browser.evaluate_on(node: node, expression: expression)
        end

        def node_visible?(node)
          evaluate_on(node, "!!(this.offsetWidth || this.offsetHeight || this.getClientRects().length)")
        end

        def selector_state?(selector, state)
          node = find_node(selector)
          case state
          when "attached" then !node.nil?
          when "detached" then node.nil?
          when "hidden"   then node.nil? || !node_visible?(node)
          else                 !node.nil? && node_visible?(node) # visible
          end
        end

        def set_checked(selector, value)
          checked = [true, "true", "1", "on", "yes"].include?(value)
          evaluate_on(
            wait_for_node(selector, visible: false),
            "this.checked = #{checked}; this.dispatchEvent(new Event('change', { bubbles: true }))",
          )
        end

        def select_options(selector, value, multiple: false)
          values = multiple ? value.to_s.split(",").map(&:strip) : [value.to_s]
          evaluate_on(wait_for_node(selector, visible: false), <<~JS)
            var values = #{JSON.generate(values)};
            Array.from(this.options).forEach(function(o) { o.selected = values.indexOf(o.value) !== -1 || values.indexOf(o.textContent.trim()) !== -1; });
            this.dispatchEvent(new Event('change', { bubbles: true }));
          JS
        end

        def poll(timeout_ms, failure_message)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (timeout_ms / 1000.0)
          loop do
            return true if yield

            raise "timed out after #{timeout_ms}ms: #{failure_message}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 0.1
          end
        end
    end
  end
end
