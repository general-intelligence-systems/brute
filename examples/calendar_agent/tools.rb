# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"
require "time"
require_relative "provider"

module CalendarAgent
  # Generic calendar tools, ported from inference-gateway/google-calendar-agent
  # (tools/*.go). Tool names, descriptions, and parameter descriptions are
  # copied verbatim — with "Google Calendar" generalized to the injected
  # provider's display_name, since the tools work against any Provider.
  #
  # Tools are RubyLLM::Tool subclasses, same as Brute::Tools::*, constructed
  # with the provider they talk to: CalendarAgent::Tools.build(provider).
  module Tools
    # Base class: every calendar tool wraps a Provider.
    class CalendarTool < RubyLLM::Tool
      def initialize(provider)
        @provider = provider
      end

      private

        attr_reader :provider
    end

    class GetCurrentDatetime < CalendarTool
      description "Return the current date/time and the user's IANA timezone. Call this FIRST " \
                  "for any time-relative request (today, tomorrow, next Friday) before emitting " \
                  "RFC3339 timestamps to other calendar tools, so events land in the user's " \
                  "local timezone instead of an LLM-assumed default."

      def name = "get_current_datetime"

      def execute
        now = Time.now
        JSON.generate(
          datetime: now.iso8601,
          timezone: ENV["CALENDAR_AGENT_TIMEZONE"] || ENV["TZ"] || now.zone,
        )
      end
    end

    class ListCalendarEvents < CalendarTool
      param :maxResults, type: "number", desc: "Maximum number of events to return (default: 10, max: 100)", required: false
      param :query, type: "string", desc: "Free text search terms to find events. Optional.", required: false
      param :timeMin, type: "string", desc: "Start time (RFC3339 format, e.g., 2024-01-01T00:00:00Z). Defaults to now.", required: false
      param :timeMax, type: "string", desc: "End time (RFC3339 format, e.g., 2024-01-01T23:59:59Z). Optional.", required: false

      def name = "list_calendar_events"

      def description = "List upcoming events from #{provider.display_name}"

      def execute(maxResults: 10, query: nil, timeMin: nil, timeMax: nil)
        events = provider.list_events(
          time_min:    timeMin || Time.now.utc.iso8601,
          time_max:    timeMax,
          query:       query,
          max_results: [[maxResults.to_i, 1].max, 100].min,
        )
        JSON.generate(success: true, count: events.size, events: events)
      end
    end

    class GetCalendarEvent < CalendarTool
      param :eventId, type: "string", desc: "Event ID to retrieve (required)", required: true

      def name = "get_calendar_event"

      def description = "Get details of a specific event from #{provider.display_name}"

      def execute(eventId:)
        event = provider.get_event(eventId)
        raise "event not found: #{eventId}" unless event

        JSON.generate(success: true, event: event)
      end
    end

    class CreateCalendarEvent < CalendarTool
      # attendees is an array param — declared via the params(...) schema
      # DSL, which RubyLLM::Tool's per-field `param` can't express.
      params({
        type: "object",
        properties: {
          summary:     { type: "string", description: "Event title/summary (required)" },
          startTime:   { type: "string", description: "Start time in RFC3339 format (required, e.g., 2024-01-01T10:00:00Z)" },
          endTime:     { type: "string", description: "End time in RFC3339 format (required, e.g., 2024-01-01T11:00:00Z)" },
          description: { type: "string", description: "Event description. Optional." },
          location:    { type: "string", description: "Event location. Optional." },
          attendees:   { type: "array", items: { type: "string" }, description: "List of attendee email addresses. Optional." },
        },
        required: %w[summary startTime endTime],
      })

      def name = "create_calendar_event"

      def description = "Create a new event in #{provider.display_name}"

      def execute(summary:, startTime:, endTime:, description: nil, location: nil, attendees: nil)
        event = provider.create_event({
          summary:     summary,
          start_time:  startTime,
          end_time:    endTime,
          description: description,
          location:    location,
          attendees:   attendees,
        }.compact)
        JSON.generate(success: true, event: event)
      end
    end

    class UpdateCalendarEvent < CalendarTool
      param :eventId, type: "string", desc: "Event ID to update (required)", required: true
      param :summary, type: "string", desc: "Event title/summary. Optional.", required: false
      param :startTime, type: "string", desc: "Start time in RFC3339 format. Optional.", required: false
      param :endTime, type: "string", desc: "End time in RFC3339 format. Optional.", required: false
      param :description, type: "string", desc: "Event description. Optional.", required: false
      param :location, type: "string", desc: "Event location. Optional.", required: false

      def name = "update_calendar_event"

      def description = "Update an existing event in #{provider.display_name}"

      def execute(eventId:, summary: nil, startTime: nil, endTime: nil, description: nil, location: nil)
        event = provider.update_event(eventId, {
          summary:     summary,
          start_time:  startTime,
          end_time:    endTime,
          description: description,
          location:    location,
        }.compact)
        JSON.generate(success: true, event: event)
      end
    end

    class DeleteCalendarEvent < CalendarTool
      param :eventId, type: "string", desc: "Event ID to delete (required)", required: true

      def name = "delete_calendar_event"

      def description = "Delete an event from #{provider.display_name}"

      def execute(eventId:)
        provider.delete_event(eventId)
        JSON.generate(success: true, eventId: eventId, message: "Event deleted successfully")
      end
    end

    class CheckConflicts < CalendarTool
      description "Check for scheduling conflicts in the specified time range"

      param :startTime, type: "string", desc: "Start time to check (RFC3339 format, required)", required: true
      param :endTime, type: "string", desc: "End time to check (RFC3339 format, required)", required: true

      def name = "check_conflicts"

      def execute(startTime:, endTime:)
        conflicts = provider.check_conflicts(start_time: startTime, end_time: endTime)
        JSON.generate(
          success:      true,
          hasConflicts: conflicts.any?,
          conflicts:    conflicts,
          timeRange:    { startTime: startTime, endTime: endTime },
        )
      end
    end

    class FindAvailableTime < CalendarTool
      description "Find available time slots in the calendar"

      param :startDate, type: "string", desc: "Start date for search (RFC3339 format, e.g., 2024-01-01T00:00:00Z)", required: true
      param :endDate, type: "string", desc: "End date for search (RFC3339 format, e.g., 2024-01-01T23:59:59Z)", required: true
      param :duration, type: "number", desc: "Duration in minutes for the desired time slot (default: 60)", required: false

      def name = "find_available_time"

      def execute(startDate:, endDate:, duration: 60)
        events = provider.list_events(time_min: startDate, time_max: endDate, max_results: 100)
        slots  = available_slots(Time.parse(startDate), Time.parse(endDate), duration.to_i * 60, events)
        JSON.generate(
          success:           true,
          availableSlots:    slots,
          slotCount:         slots.size,
          requestedDuration: duration.to_i,
          searchRange:       { startDate: startDate, endDate: endDate },
        )
      end

      private

        # Gap-finding between busy periods, mirroring google-calendar-agent's
        # findAvailableSlots: a slot before the first event, one per gap
        # between events, and one after the last event.
        def available_slots(start_date, end_date, duration_seconds, events)
          busy = events
            .select { |e| e[:start_time] && e[:end_time] }
            .map    { |e| [Time.parse(e[:start_time]), Time.parse(e[:end_time])] }
            .sort_by(&:first)

          slot = ->(start_time) {
            {
              startTime: start_time.iso8601,
              endTime:   (start_time + duration_seconds).iso8601,
              duration:  duration_seconds / 60,
            }
          }

          return [slot.call(start_date)] if busy.empty?

          slots = []
          slots << slot.call(start_date) if busy.first[0] - start_date >= duration_seconds

          busy.each_cons(2) do |(_, gap_start), (gap_end, _)|
            slots << slot.call(gap_start) if gap_end - gap_start >= duration_seconds
          end

          slots << slot.call(busy.last[1]) if end_date - busy.last[1] >= duration_seconds
          slots
        end
    end

    ALL = [
      GetCurrentDatetime,
      ListCalendarEvents,
      GetCalendarEvent,
      CreateCalendarEvent,
      UpdateCalendarEvent,
      DeleteCalendarEvent,
      CheckConflicts,
      FindAvailableTime,
    ].freeze

    # Instantiate every tool against the given provider.
    def self.build(provider)
      ALL.map { |tool| tool.new(provider) }
    end
  end
end
