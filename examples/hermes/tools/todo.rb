# frozen_string_literal: true

require "json"

module HermesTools
  # todo — task tracking for the agent. Port of hermes-agent tools/todo_tool.py.
  # The store is injected per turn by Hermes::Middleware::Todo; a storeless
  # instance reports unavailable.
  class Todo < Brute::Tool
    description "Track tasks for this session: write a todo list (or merge updates), " \
                "read it back with a status summary. List order is priority order."
    params({
      "type" => "object",
      "properties" => {
        "todos" => {
          "type" => "array",
          "description" => "Todo items: {id, content, status}. status: pending|in_progress|completed|cancelled.",
          "items" => {
            "type" => "object",
            "properties" => {
              "id" => { "type" => "string" },
              "content" => { "type" => "string" },
              "status" => { "type" => "string", "enum" => %w[pending in_progress completed cancelled] },
            },
            "required" => %w[id content],
          },
        },
        "merge" => { "type" => "boolean", "description" => "Merge by id (update provided fields only) instead of replacing (default false).", "default" => false },
      },
      "required" => [],
    })

    def initialize(store = nil)
      @store = store
    end

    def name = "todo"

    def execute(todos: nil, merge: false, **_rest)
      return err("Todo store unavailable.") unless @store

      @store.write(todos, merge: merge) if todos.is_a?(Array)
      JSON.dump(
        "todos" => @store.items.map { |i| i.transform_keys(&:to_s) },
        "summary" => @store.summary.transform_keys(&:to_s),
      )
    end

    private

    def err(message)
      JSON.dump("error" => message)
    end
  end
end
