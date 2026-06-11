# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "securerandom"
require "time"
require_relative "../provider"

module CalendarAgent
  module Providers
    # In-memory provider — the equivalent of google-calendar-agent's mock
    # mode. Lets the agent run end-to-end with no credentials, and doubles
    # as a template for the smallest possible provider implementation.
    class InMemory < Provider
      def initialize(events: nil)
        now = Time.now.utc
        @events = {}
        (events || seed_events(now)).each { |event| @events[event[:id]] = event }
      end

      def display_name
        "in-memory calendar (demo mode)"
      end

      def list_events(time_min:, time_max: nil, query: nil, max_results: 10)
        events = @events.values.sort_by { |e| e[:start_time] }
        events = events.select { |e| e[:end_time] > time_min } if time_min
        events = events.select { |e| e[:start_time] < time_max } if time_max
        if query
          q = query.downcase
          events = events.select { |e| [e[:summary], e[:description], e[:location]].compact.any? { |v| v.downcase.include?(q) } }
        end
        events.first(max_results)
      end

      def get_event(event_id)
        @events[event_id]
      end

      def create_event(event)
        created = event.merge(id: "evt_#{SecureRandom.hex(4)}", status: "confirmed")
        @events[created[:id]] = created
        created
      end

      def update_event(event_id, attrs)
        event = @events.fetch(event_id) { raise "event not found: #{event_id}" }
        @events[event_id] = event.merge(attrs.compact)
      end

      def delete_event(event_id)
        @events.delete(event_id) or raise "event not found: #{event_id}"
        true
      end

      private

        def seed_events(now)
          today_at = ->(hour) { Time.utc(now.year, now.month, now.day, hour).iso8601 }
          [
            {
              id:         "evt_demo1",
              summary:    "Team standup",
              start_time: today_at.call(9),
              end_time:   today_at.call(10) ,
              attendees:  ["team@example.com"],
              status:     "confirmed",
            },
            {
              id:         "evt_demo2",
              summary:    "Lunch with Sam",
              location:   "Cafe Brute",
              start_time: today_at.call(12),
              end_time:   today_at.call(13),
              attendees:  ["sam@example.com"],
              status:     "confirmed",
            },
          ]
        end
    end
  end
end
