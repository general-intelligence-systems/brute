# frozen_string_literal: true

require "bundler/setup"
require "brute"

module BrowserAgent
  # Browser driver interface — the browser agent is driver-agnostic; all
  # engine-specific work happens behind this interface (upstream uses
  # Playwright; the reference implementation here is drivers/ferrum.rb,
  # driving Chrome over CDP).
  #
  # To use another engine (Selenium, Watir, playwright-ruby-client, ...),
  # copy drivers/ferrum.rb and implement these methods.
  class Driver
    # Navigate and wait for the page to load. Returns { url:, title: }.
    def goto(url:, wait_until: "load", timeout_ms: 30_000)
      raise NotImplementedError, "#{self.class}#goto"
    end

    # Click an element. Returns { selector:, clicked: true }.
    def click(selector:, button: "left", click_count: 1, force: false, timeout_ms: 30_000)
      raise NotImplementedError, "#{self.class}#click"
    end

    # Fill form fields ({selector:, value:, type:, multiple:} each), then
    # optionally submit. Returns { filled: [...], submitted: bool }.
    def fill(fields:, submit: false, submit_selector: nil)
      raise NotImplementedError, "#{self.class}#fill"
    end

    # Evaluate JavaScript in the page context. Returns the script result.
    def evaluate(script:, args: [], async: false, timeout_ms: 30_000)
      raise NotImplementedError, "#{self.class}#evaluate"
    end

    # Run extractors ({name:, selector:, attribute:, multiple:} each).
    # Returns { name => value } for each extractor.
    def extract(extractors:)
      raise NotImplementedError, "#{self.class}#extract"
    end

    # Capture the page (or an element) to +path+. Returns the path.
    def screenshot(path:, full_page: false, selector: nil, format: "png", quality: 80)
      raise NotImplementedError, "#{self.class}#screenshot"
    end

    # Block until a condition holds (selector/navigation/function/timeout/
    # networkidle). Returns { condition:, met: true }.
    def wait_for(condition:, selector: nil, state: "visible", custom_function: nil, timeout_ms: 30_000)
      raise NotImplementedError, "#{self.class}#wait_for"
    end

    # Shut the browser down.
    def quit
      raise NotImplementedError, "#{self.class}#quit"
    end
  end
end
