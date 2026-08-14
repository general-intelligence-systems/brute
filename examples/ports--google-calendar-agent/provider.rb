# frozen_string_literal: true

require "bundler/setup"
require "brute"

module CalendarAgent
  # Provider adapter interface — the calendar agent is provider-agnostic;
  # all vendor-specific work happens behind this interface (mirrors the
  # CalendarService interface from inference-gateway/google-calendar-agent).
  #
  # To support another backend (CalDAV, Office 365, ...), copy
  # providers/google_calendar.rb and implement these methods. Events are
  # plain hashes, normalized to:
  #
  #   {
  #     id:          "evt_123",
  #     summary:     "Standup",
  #     description: "Daily sync",          # optional
  #     location:    "Room 4",              # optional
  #     start_time:  "2026-06-11T10:00:00Z",  # RFC3339
  #     end_time:    "2026-06-11T10:30:00Z",  # RFC3339
  #     attendees:   ["a@example.com"],
  #     status:      "confirmed",
  #   }
  #
  class Provider
    # Human-readable backend name, interpolated into the agent's prompt
    # and tool descriptions (e.g. "Google Calendar").
    def display_name
      "Calendar"
    end

    # Return events overlapping [time_min, time_max] (RFC3339 strings).
    # query is an optional free-text filter; max_results caps the list.
    def list_events(time_min:, time_max: nil, query: nil, max_results: 10)
      raise NotImplementedError, "#{self.class}#list_events"
    end

    # Return a single event hash by id, or nil when not found.
    def get_event(event_id)
      raise NotImplementedError, "#{self.class}#get_event"
    end

    # Create an event from a normalized event hash (no :id). Returns the
    # created event hash (with :id).
    def create_event(event)
      raise NotImplementedError, "#{self.class}#create_event"
    end

    # Patch an existing event with the given attributes (only provided
    # keys change). Returns the updated event hash.
    def update_event(event_id, attrs)
      raise NotImplementedError, "#{self.class}#update_event"
    end

    # Delete an event by id. Returns true on success.
    def delete_event(event_id)
      raise NotImplementedError, "#{self.class}#delete_event"
    end

    # Events overlapping [start_time, end_time] — scheduling conflicts.
    # Default implementation filters list_events; providers with a native
    # free/busy API can override.
    def check_conflicts(start_time:, end_time:)
      list_events(time_min: start_time, time_max: end_time, max_results: 100).select do |event|
        event[:start_time] && event[:end_time] &&
          event[:start_time] < end_time && event[:end_time] > start_time
      end
    end
  end
end
