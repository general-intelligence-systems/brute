#!/usr/bin/env ruby
# frozen_string_literal: true

# Session persistence — run the agent, then resume the same conversation.
#
# Uses a local Ollama instance. Start Ollama first:
#   ollama serve
#   ollama pull qwen2.5:14b

require_relative "../lib/brute"
require "json"

ollama = Brute::Providers::Ollama.new

session = Brute::Session.new
session_id = session.id

agent = Brute.agent(provider: ollama, model: "qwen2.5:14b", cwd: Dir.pwd, session: session)
agent.run("Remember this: the secret project codename is FALCON. Just acknowledge.")

resumed_session = Brute::Session.new(id: session_id)
resumed_agent = Brute.agent(provider: ollama, model: "qwen2.5:14b", cwd: Dir.pwd, session: resumed_session)
resumed_agent.run("What is the secret project codename I told you?")

resumed_agent.message_store.messages.each { |msg| puts JSON.generate(msg) }

session.delete
