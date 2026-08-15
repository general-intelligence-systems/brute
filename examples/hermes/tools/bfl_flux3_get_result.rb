# frozen_string_literal: true

require "json"

# bfl_flux3_get_result — hermes toolset: bfl
# Port of hermes-agent `tools/flux3_video_tool.py:1229` (registry.register).
# Scaffold: no-op handler, returns a JSON error string (hermes tool_error convention).
# hermes check_fn: check_bfl_requirements
module HermesTools
  class BflFlux3GetResult < Brute::Tool
    description "Poll a FLUX 3 video job by the job id a generate tool returned. Generation takes minutes and a long Generating phase is normal. This call waits for you while the job runs, so it may run for several minutes; if it returns still generating, just call it again. Do not sleep between calls. On Ready the clip is downloaded for you and the response gives its local path; your only remaining step is to deliver that file as the response describes."
    params({ "type" => "object", "properties" => { "id" => { "type" => "string", "minLength" => 1, "description" => "Job id from a previous bfl_flux3_* generate call." }, "save_to" => { "type" => "string", "description" => "Where to save the finished clip: a directory or a full file path. Set this only when the user asked for a particular location; the default is ~/Downloads. An existing file is never overwritten." } }, "required" => ["id"], "additionalProperties" => false })
    def name = "bfl_flux3_get_result"

    def execute(**_args)
      JSON.dump("error" => "not implemented", "tool" => "bfl_flux3_get_result")
    end
  end
end
