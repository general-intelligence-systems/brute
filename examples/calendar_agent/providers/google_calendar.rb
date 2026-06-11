# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"
require "net/http"
require_relative "../provider"

module CalendarAgent
  module Providers
    # Google Calendar adapter, talking to the Calendar v3 REST API.
    #
    # This is the reference provider implementation — to support another
    # backend (CalDAV, Office 365, ...), copy this file and reimplement
    # the same methods against your vendor's API.
    #
    # Configuration:
    #
    #   GOOGLE_CALENDAR_ACCESS_TOKEN  OAuth2 bearer token. For quick local
    #                                 testing: gcloud auth print-access-token
    #                                 --scopes=https://www.googleapis.com/auth/calendar
    #                                 Production code should mint tokens with
    #                                 the googleauth gem (OAuth or service
    #                                 account) instead of a static env var.
    #   GOOGLE_CALENDAR_ID            Calendar to operate on (default: "primary").
    #
    class GoogleCalendar < Provider
      BASE_URL = "https://www.googleapis.com/calendar/v3"

      def initialize(access_token: ENV.fetch("GOOGLE_CALENDAR_ACCESS_TOKEN"),
                     calendar_id: ENV.fetch("GOOGLE_CALENDAR_ID", "primary"))
        @access_token = access_token
        @calendar_id  = calendar_id
      end

      def display_name
        "Google Calendar"
      end

      def list_events(time_min:, time_max: nil, query: nil, max_results: 10)
        params = {
          singleEvents: "true",
          orderBy:      "startTime",
          timeMin:      time_min,
          timeMax:      time_max,
          q:            query,
          maxResults:   max_results,
        }.compact

        data = request(:get, "/calendars/#{escape(@calendar_id)}/events", params: params)
        (data["items"] || []).map { |item| normalize(item) }
      end

      def get_event(event_id)
        normalize(request(:get, event_path(event_id)))
      end

      def create_event(event)
        normalize(request(:post, "/calendars/#{escape(@calendar_id)}/events", body: denormalize(event)))
      end

      def update_event(event_id, attrs)
        normalize(request(:patch, event_path(event_id), body: denormalize(attrs)))
      end

      def delete_event(event_id)
        request(:delete, event_path(event_id))
        true
      end

      private

        def event_path(event_id)
          "/calendars/#{escape(@calendar_id)}/events/#{escape(event_id)}"
        end

        def escape(component)
          URI.encode_uri_component(component)
        end

        def request(method, path, params: nil, body: nil)
          uri = URI("#{BASE_URL}#{path}")
          uri.query = URI.encode_www_form(params) if params&.any?

          request = Net::HTTP.const_get(method.capitalize).new(uri)
          request["Authorization"] = "Bearer #{@access_token}"
          if body
            request["Content-Type"] = "application/json"
            request.body = JSON.generate(body)
          end

          response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }

          unless response.is_a?(Net::HTTPSuccess)
            raise "Google Calendar API request failed: #{response.code} #{response.message} — #{response.body}"
          end

          response.body.to_s.empty? ? {} : JSON.parse(response.body)
        end

        # Google event resource → normalized event hash.
        def normalize(item)
          {
            id:          item["id"],
            summary:     item["summary"],
            description: item["description"],
            location:    item["location"],
            start_time:  item.dig("start", "dateTime") || item.dig("start", "date"),
            end_time:    item.dig("end", "dateTime") || item.dig("end", "date"),
            attendees:   (item["attendees"] || []).map { |a| a["email"] },
            status:      item["status"],
          }.compact
        end

        # Normalized event hash → Google event resource (only given keys).
        def denormalize(event)
          resource = {
            "summary"     => event[:summary],
            "description" => event[:description],
            "location"    => event[:location],
          }.compact

          resource["start"]     = { "dateTime" => event[:start_time] } if event[:start_time]
          resource["end"]       = { "dateTime" => event[:end_time] }   if event[:end_time]
          resource["attendees"] = event[:attendees].map { |email| { "email" => email } } if event[:attendees]

          resource
        end
    end
  end
end
