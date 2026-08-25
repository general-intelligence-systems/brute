---
title: Prompt Architecture
description: The system prompt is assembled from provider-specific stacks of small
  modules, rendered at turn time against a runtime context.
sidebar:
  order: 9
---

Brute's default system prompt is not one string — it is a stack of small prompt modules selected per provider and rendered at turn time. `Brute::Middleware::SystemPrompt` prepends the result as the `:system` message (unless one already exists in the log).

## Deferred building

`Brute::SystemPrompt.build` stores a block; it runs only when `prepare` receives a runtime context:

```ruby
sp = Brute::SystemPrompt.build do |prompt, ctx|
  prompt << Brute::Prompts::Identity.call(ctx)
  prompt << Brute::Prompts::Environment.call(ctx)
end

sp.prepare(provider_name: "anthropic", model_name: "claude-...", cwd: Dir.pwd)
#  => #<SystemPrompt::Result> — .to_s (joined) or .sections (one per module)
```

Deferral matters because modules adapt to the context: which model family is running, what the working directory holds, which skills were discovered. Nothing is frozen at agent-construction time.

## Provider stacks

`Brute::SystemPrompt.default` picks an ordered module list from `STACKS` by provider — `"anthropic"`, `"openai"`, `"google"`, with `"default"` as the fallback. Gateway providers (`opencode_*`) infer the upstream model family from the model name, so a `claude-*` model behind a gateway gets the Anthropic stack.

The Anthropic stack, for illustration: Identity, ToneAndStyle, Objectivity, TaskManagement, DoingTasks, ToolUsage, Conventions, GitSafety, CodeReferences, Environment, Skills, Instructions. Other providers get leaner variants; several modules also carry per-provider text templates under `lib/brute/prompts/text/` (e.g. `identity/anthropic.txt`, `identity/google.txt`) so even shared sections speak each model's dialect.

## Conditional sections

After the base stack, the default builder appends reminders based on runtime state:

| Condition | Module |
|---|---|
| `ctx[:agent] == "plan"` | `Prompts::PlanReminder` |
| `ctx[:agent_switched] == "build"` | `Prompts::BuildSwitch` |
| `ctx[:max_steps_reached]` | `Prompts::MaxSteps` |

## A module is just `.call(ctx) -> String-or-nil`

Every prompt module answers one class method. `Prompts::Skills` is typical — its ERB template renders only each skill's *name, description, and location* into `<available_skills>` (the body loads later via the `skill` tool), reading skills from `ctx[:skills]` or scanning `ctx[:cwd]`.

## Custom prompts

Pass your own to the middleware — built from any mix of Brute modules and your own text:

```ruby
sp = Brute::SystemPrompt.build do |prompt, ctx|
  prompt << "You are a release engineer for #{ctx[:cwd]}."
  prompt << Brute::Prompts::GitSafety.call(ctx)
  prompt << Brute::Prompts::Skills.call(ctx)   # scans cwd when no ctx[:skills]
end

Brute.agent.use(Brute::Middleware::SystemPrompt, system_prompt: sp)
```
