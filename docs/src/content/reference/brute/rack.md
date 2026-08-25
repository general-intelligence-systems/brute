---
title: "Brute::Rack"
description: "The mirror image of protocol-rack."
---


```ruby
module Brute
  module Rack
  end
end
```

The mirror image of protocol-rack. Where <code>Protocol::Rack::Adapter</code>
wraps a *Rack app* so an HTTP server can drive it (env in, `[status, headers,
body]` out), <code>Brute::Rack::Adapter</code> wraps a *Brute agent* so a
[`Rack`](/brute/reference/brute/rack/) server can drive it. It is itself a
[`Rack`](/brute/reference/brute/rack/) app — `call(env) -> [status, headers,
body]` —so any AgentPipeline drops straight into a config.ru and serves over
HTTP behind Falcon/Puma/etc:


```sh
# config.ru
agent = Brute::Turn::AgentPipeline.parse_file("examples/agents/brute.ru")
run Brute::Rack::Adapter.for(agent)

$ curl -d 'What files are here?' localhost:9292
$ curl -H 'content-type: application/json' -d '{"prompt":"hi"}' localhost:9292
$ curl 'localhost:9292/?prompt=hi'
```

The whole job is two pure transforms — the two directions the request named:


```
env    -> prompt string      (#prompt_from)   the request half
output -> [status, headers, body] (#response_for) the response half
```

`call` just wires them together around one <code>agent.start</code>.

## Defined in

- `lib/brute/rack/adapter.rb`
