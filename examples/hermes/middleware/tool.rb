# frozen_string_literal: true

# The canonical per-call tool middleware (MIDDLEWARE.md §4). The literal
# `.use` list lives in main.rb's build_tool — order is load-bearing (§6).

require_relative "tool/coerce_args"
require_relative "tool/availability_gate"
require_relative "tool/safety_guard"
require_relative "tool/edit_approval"
require_relative "tool/approval"
require_relative "tool/read_loop_guard"
require_relative "tool/transform_result"
require_relative "tool/audit"
require_relative "tool/result_caps"
require_relative "tool/secret_redact"
require_relative "tool/result_normalize"
require_relative "tool/error_wrap"
