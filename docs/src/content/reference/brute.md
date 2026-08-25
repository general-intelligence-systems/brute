---
title: "Brute"
description: "Module Brute."
---


```ruby
module Brute
end
```

## Constants

### LOGO

```ruby
LOGO = <<-LOGO
```

*Not documented.*

### Message

```ruby
Message = Data.define(:role, :content, :tool_calls, :tool_call_id) do
    def initialize(role:, content: nil, tool_calls: nil, tool_call_id: nil)
      formatted_calls = tool_calls&.map do |tc|
        tc.is_a?(ToolCall) ? tc : ToolCall.new(**tc.to_h.transform_keys(&:to_sym))
      end
  
      super(
        role: role.to_sym,
        content: content,
        tool_calls: formatted_calls,
        tool_call_id: tool_call_id
      )
    end
  
    def tool_call? = !tool_calls.nil? && !tool_calls.empty?
    alias_method :has_tool_calls?, :tool_call?
  
    # Clean, JSON-ready hash export dropping nil values
    def to_h(...)
      hash = super
      hash[:tool_calls] = tool_calls.map(&:to_h) if tool_calls
      hash.compact
    end
  end
```

Brute's canonical, framework-agnostic message. The rest of the stack
(middleware, tool loop, persistence) never calls anything beyond #role,
#content, #tool_calls, #tool_call_id and #to_h — so any object that duck-types
those methods can ride in `env[:messages]` too. This Data class is simply the
canonical implementation.


```ruby
Brute::Message.new(role: :user, content: "hi")
Brute::Message.new(role: :assistant, content: "", tool_calls: [
  Brute::ToolCall.new(id: "tc1", name: "shell", arguments: { "command" => "ls" }),
])
Brute::Message.new(role: :tool, content: "result", tool_call_id: "tc1")
```

### ToolCall

```ruby
ToolCall = Data.define(:id, :name, :arguments) do
    def initialize(id:, name:, arguments: {})
      super(id: id, name: name.to_s, arguments: arguments.to_h)
    end
  end
```

One tool invocation requested by the model. Arguments are always a Hash.

### VERSION

```ruby
VERSION = "5.1.0"
```

*Not documented.*

## Class Methods

### self.agent

```ruby
agent(&block)
```

Start building an agent turn. Returns an AgentPipeline — a rack-style builder
that is also the runnable Agent: chain <code>.use</code> for middleware and
<code>.run</code> for the terminal LLM-call proc (both return the
AgentPipeline), then invoke it with <code>#start</code>. It takes no config —
LLM config lives in the `run` proc, tools go to the ToolPipeline middleware,
the log to SessionLog.


```
agent = Brute.agent
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::DefaultToolPipeline, tools: Brute::Tools::ALL)
  .run ->(env) { ... }      # the LLM-call proc (provider/model/creds here)

agent.start("what changed?")
```

A block form is equivalent (evaluated in the AgentPipeline's context):


```
Brute.agent do
  use Brute::Middleware::SystemPrompt
  run ->(env) { ... }
end
```

### self.load_agent

```ruby
load_agent(path = "agent.ru")
```

Load an agent from a brute.ru file — the [`Brute`](/brute/reference/brute/)
analogue of `rackup`. The file is a rackup-style script using the same `use` /
`run` / `map` DSL as <code>Brute.agent</code>, and what comes back is the
AgentPipeline itself, so it can be started, further `.use`d, or served through
[`Brute::Rack::Adapter`](/brute/reference/brute/rack/adapter/):


```ruby
Brute.load_agent.start("what changed?")               # ./agent.ru
Brute.load_agent("examples/agents/brute.ru").start("hi")
```

### self.log

```ruby
log(*messages)
```

Build a fresh conversation log (an Array +
[`Messages`](/brute/reference/brute/messages/) sugar), optionally seeded with
messages.


```ruby
log = Brute.log
log.user("hello")
Brute.log(Brute::Message.new(role: :user, content: "hi"))
```

### self.provider

```ruby
provider()
```

NOTE: [`Brute`](/brute/reference/brute/) owns no LLM configuration and no LLM
library. All provider/model/credential config lives in the pipeline's terminal
`run` proc, which the user writes with whatever LLM library they prefer
(ruby_llm, llm.rb, openai, anthropic, raw HTTP, ...). The proc converts
`env[:messages]` ([`Brute::Message`](/brute/reference/brute/#message) values —
see [`Brute.log`](/brute/reference/brute/#selflog)) to the library's format,
makes the call, and appends the response back as
[`Brute::Message`](/brute/reference/brute/#message) values — the
[`MessageTransport`](/brute/reference/brute/message-transport/) pattern. See
examples/ruby_llm.rb, examples/llm.rb, examples/openai.rb and
examples/anthropic.rb.

### self.provider=

```ruby
provider=(p)
```

*Not documented.*

### self.tools

```ruby
tools(tools)
```

Adapt any [`Brute`](/brute/reference/brute/) tools (hashes,
[`Brute::Tool`](/brute/reference/brute/tool/),
[`Brute::Turn::ToolPipeline`](/brute/reference/brute/turn/tool-pipeline/),
SubAgent …) into a { name_sym =>
[`Brute::Tools::Adapter`](/brute/reference/brute/tools/adapter/) } hash. Each
adapter exposes #to_h — a neutral JSON-Schema-ish definition the inline `run`
proc converts to whatever its LLM library expects.

## Defined in

- `lib/brute.rb`
- `lib/brute/compaction.rb`
- `lib/brute/compaction/middleware/sliding_window.rb`
- `lib/brute/compaction/middleware/strategy.rb`
- `lib/brute/compaction/middleware/tool_results.rb`
- `lib/brute/compaction/summarize.rb`
- `lib/brute/compaction/transcript.rb`
- `lib/brute/completion/lang_chain.rb`
- `lib/brute/completion/llmrb.rb`
- `lib/brute/completion/open_router.rb`
- `lib/brute/completion/ruby_llm.rb`
- `lib/brute/contrib/log_file.rb`
- `lib/brute/contrib/otel.rb`
- `lib/brute/env.rb`
- `lib/brute/eval.rb`
- `lib/brute/eval/case.rb`
- `lib/brute/eval/suite.rb`
- `lib/brute/eval/transcript.rb`
- `lib/brute/eval/world.rb`
- `lib/brute/events/handler.rb`
- `lib/brute/events/prefixed_terminal_output.rb`
- `lib/brute/events/terminal_output_handler.rb`
- `lib/brute/hooks.rb`
- `lib/brute/message_transport.rb`
- `lib/brute/message_transport/anthropic.rb`
- `lib/brute/message_transport/lang_chain.rb`
- `lib/brute/message_transport/llm.rb`
- `lib/brute/message_transport/open_router.rb`
- `lib/brute/message_transport/openai.rb`
- `lib/brute/message_transport/ruby_llm.rb`
- `lib/brute/message_transport/ruby_open_ai.rb`
- `lib/brute/messages.rb`
- `lib/brute/middleware/000_base.rb`
- `lib/brute/middleware/001_slash_commands.rb`
- `lib/brute/middleware/002_session_log.rb`
- `lib/brute/middleware/004_summarize.rb`
- `lib/brute/middleware/006_loop.rb`
- `lib/brute/middleware/008_checkpoint.rb`
- `lib/brute/middleware/010_max_iterations.rb`
- `lib/brute/middleware/020_system_prompt.rb`
- `lib/brute/middleware/025_skills.rb`
- `lib/brute/middleware/040_compaction_check.rb`
- `lib/brute/middleware/040_default_compaction_pipeline.rb`
- `lib/brute/middleware/060_questions.rb`
- `lib/brute/middleware/070_default_tool_pipeline.rb`
- `lib/brute/middleware/070_tool_pipeline.rb`
- `lib/brute/middleware/event_handler.rb`
- `lib/brute/middleware/user_queue.rb`
- `lib/brute/prompt_template.rb`
- `lib/brute/prompts.rb`
- `lib/brute/prompts/autonomy.rb`
- `lib/brute/prompts/base.rb`
- `lib/brute/prompts/build_switch.rb`
- `lib/brute/prompts/code_references.rb`
- `lib/brute/prompts/code_style.rb`
- `lib/brute/prompts/conventions.rb`
- `lib/brute/prompts/doing_tasks.rb`
- `lib/brute/prompts/editing_approach.rb`
- `lib/brute/prompts/editing_constraints.rb`
- `lib/brute/prompts/environment.rb`
- `lib/brute/prompts/frontend_tasks.rb`
- `lib/brute/prompts/git_safety.rb`
- `lib/brute/prompts/identity.rb`
- `lib/brute/prompts/instructions.rb`
- `lib/brute/prompts/max_steps.rb`
- `lib/brute/prompts/objectivity.rb`
- `lib/brute/prompts/plan_reminder.rb`
- `lib/brute/prompts/proactiveness.rb`
- `lib/brute/prompts/security_and_safety.rb`
- `lib/brute/prompts/skills.rb`
- `lib/brute/prompts/task_management.rb`
- `lib/brute/prompts/tone_and_style.rb`
- `lib/brute/prompts/tool_usage.rb`
- `lib/brute/rack/adapter.rb`
- `lib/brute/skill.rb`
- `lib/brute/system_prompt.rb`
- `lib/brute/token_counter.rb`
- `lib/brute/token_counter/approximate.rb`
- `lib/brute/token_counter/tiktoken.rb`
- `lib/brute/tool.rb`
- `lib/brute/tools.rb`
- `lib/brute/tools/adapter.rb`
- `lib/brute/tools/fs/file_mutation_queue.rb`
- `lib/brute/tools/fs/snapshot_store.rb`
- `lib/brute/tools/fs_patch.rb`
- `lib/brute/tools/fs_read.rb`
- `lib/brute/tools/fs_remove.rb`
- `lib/brute/tools/fs_search.rb`
- `lib/brute/tools/fs_undo.rb`
- `lib/brute/tools/fs_write.rb`
- `lib/brute/tools/net_fetch.rb`
- `lib/brute/tools/question.rb`
- `lib/brute/tools/shell.rb`
- `lib/brute/tools/skill_load.rb`
- `lib/brute/tools/sub_agent.rb`
- `lib/brute/tools/todo_list/store.rb`
- `lib/brute/tools/todo_read.rb`
- `lib/brute/tools/todo_write.rb`
- `lib/brute/truncation.rb`
- `lib/brute/turn/agent_pipeline.rb`
- `lib/brute/turn/compaction_pipeline.rb`
- `lib/brute/turn/pipeline.rb`
- `lib/brute/turn/tool_pipeline.rb`
- `lib/brute/usage_detection/lang_chain.rb`
- `lib/brute/usage_detection/llmrb.rb`
- `lib/brute/usage_detection/open_router.rb`
- `lib/brute/usage_detection/ruby_llm.rb`
- `lib/brute/usage_detection/usage.rb`
- `lib/brute/utils/diff.rb`
- `lib/brute/version.rb`
