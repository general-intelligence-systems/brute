# frozen_string_literal: true

require "net/http"
require "ipaddr"
require "resolv"
require "uri"
require "json"

# WebHttp — the shared safe-HTTP layer for the web tools. Port of picoclaw's
# pkg/utils/http_guard.go (+ CreateHTTPClient): SSRF guards (pre-flight host
# check, per-redirect re-check, connect-time resolved-IP filtering), redirect
# cap, proxy support, and response body caps.
#
# Connect-time filtering pins Net::HTTP's `ipaddr` to the first allowed
# resolved IP (TLS SNI/Host stay the original hostname). When a proxy is
# configured the proxy resolves remotely — only the pre-flight checks apply
# (upstream's AllowConfiguredProxyFirstHop equivalent).
module WebHttp
  class Error < StandardError; end

  # --- private/restricted IP classification (IsPrivateOrRestrictedIP port) ---

  def self.ip_bytes(ip)
    ip = IPAddr.new(ip.to_s) unless ip.is_a?(IPAddr)
    ip = ip.native
    ip.ipv4? ? 4.times.map { |i| (ip.to_i >> (8 * (3 - i))) & 0xff } : 16.times.map { |i| (ip.to_i >> (8 * (15 - i))) & 0xff }
  end

  def self.private_or_restricted_ip?(ip)
    return true if ip.nil?

    ip = IPAddr.new(ip.to_s) unless ip.is_a?(IPAddr)
    ip = ip.native
    return true if ip.loopback? || ip.link_local? || ip.multicast? || ip.unspecified?

    bytes = ip_bytes(ip)
    if ip.ipv4?
      return true if bytes[0] == 10 || bytes[0] == 127 || bytes[0] == 0
      return true if bytes[0] == 172 && (16..31).cover?(bytes[1])
      return true if bytes[0] == 192 && bytes[1] == 168
      return true if bytes[0] == 169 && bytes[1] == 254
      return true if bytes[0] == 100 && (64..127).cover?(bytes[1])
      return true if bytes[0] == 198 && (18..19).cover?(bytes[1])

      return false
    end

    return true if (bytes[0] & 0xfe) == 0xfc # fc00/7
    if bytes[0] == 0x20 && bytes[1] == 0x02 # 6to4 embeds a v4 address
      return private_or_restricted_ip?(IPAddr.new("#{bytes[2]}.#{bytes[3]}.#{bytes[4]}.#{bytes[5]}"))
    end
    if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x00 && bytes[3] == 0x00 # teredo
      return private_or_restricted_ip?(IPAddr.new("#{bytes[12] ^ 0xff}.#{bytes[13] ^ 0xff}.#{bytes[14] ^ 0xff}.#{bytes[15] ^ 0xff}"))
    end
    if [0x00, 0x02].include?(bytes[8]) && bytes[9] == 0x00 && bytes[10] == 0x5e && bytes[11] == 0xfe # ISATAP
      return private_or_restricted_ip?(IPAddr.new("#{bytes[12]}.#{bytes[13]}.#{bytes[14]}.#{bytes[15]}"))
    end

    false
  rescue IPAddr::InvalidAddressError
    true
  end

  # NewPrivateHostWhitelist port: exact IPs + CIDRs. nil when empty.
  class Whitelist
    def self.build(entries)
      list = (entries || []).map(&:to_s).map(&:strip).reject(&:empty?)
      return nil if list.empty?

      exact = []
      cidrs = []
      list.each do |entry|
        begin
          addr = IPAddr.new(entry)
          entry.include?("/") ? cidrs << addr : exact << addr.native.to_s
        rescue IPAddr::InvalidAddressError
          raise Error, "invalid entry #{entry.inspect}: expected IP or CIDR"
        end
      end
      exact.empty? && cidrs.empty? ? nil : new(exact, cidrs)
    end

    def initialize(exact, cidrs)
      @exact = exact
      @cidrs = cidrs
    end

    def contains?(ip)
      return false if ip.nil?

      addr = IPAddr.new(ip.to_s).native
      @exact.include?(addr.to_s) || @cidrs.any? { |cidr| cidr.include?(addr) }
    rescue IPAddr::InvalidAddressError
      false
    end
  end

  def self.block_ip?(ip, whitelist)
    private_or_restricted_ip?(ip) && !(whitelist && whitelist.contains?(ip))
  end

  # IsObviousPrivateHost port: cheap pre-flight, no DNS.
  def self.obvious_private_host?(host, whitelist, allow_private: false)
    return false if allow_private

    h = host.to_s.downcase.strip.sub(/\.\z/, "")
    return true if h.empty?
    return true if h == "localhost" || h.end_with?(".localhost")

    begin
      ip = IPAddr.new(h)
      return block_ip?(ip, whitelist)
    rescue IPAddr::InvalidAddressError
      false
    end
  end

  # Resolve a host and return [allowed_ips, had_blocked]. DNS failures raise.
  def self.resolve_allowed(host, whitelist, allow_private: false)
    return [[host], false] if allow_private

    begin
      IPAddr.new(host)
      return block_ip?(host, whitelist) ? [[], true] : [[host], false]
    rescue IPAddr::InvalidAddressError
      # hostname — resolve below
    end

    addrs = Addrinfo.getaddrinfo(host, nil, :STREAM).map(&:ip_address).uniq
    allowed = addrs.reject { |ip| block_ip?(ip, whitelist) }
    [allowed, allowed.size < addrs.size]
  end

  # One GET request with the full guard chain + redirect following.
  # Options: headers:, timeout:, proxy: (URL string), max_redirects:,
  # max_bytes:, whitelist: (Whitelist), allow_private: (test seam).
  # Returns [Net::HTTPResponse, body_string]. Raises WebHttp::Error with the
  # upstream message on guard/transport failures.
  def self.get(url, headers: {}, timeout: 60, proxy: nil, max_redirects: 5, max_bytes: nil,
               whitelist: nil, allow_private: false)
    current = url.to_s
    redirects = 0

    loop do
      uri =
        begin
          URI.parse(current)
        rescue URI::InvalidURIError => e
          raise Error, "invalid URL: #{e.message}"
        end
      raise Error, "only http/https URLs are allowed" unless %w[http https].include?(uri.scheme)
      raise Error, "missing domain in URL" if uri.host.to_s.empty?

      first = redirects.zero?
      if obvious_private_host?(uri.host, whitelist, allow_private: allow_private)
        raise Error, first ? "fetching private or local network hosts is not allowed" : "redirect target is private or local network host"
      end

      response, body = perform(uri, headers: headers, timeout: timeout, proxy: proxy,
                                    max_bytes: max_bytes, whitelist: whitelist,
                                    allow_private: allow_private)

      if response.is_a?(Net::HTTPRedirection) && response["location"]
        redirects += 1
        raise Error, "stopped after #{max_redirects} redirects" if redirects >= max_redirects

        current = URI.join(current, response["location"]).to_s
        next
      end

      return [response, body]
    end
  end

  def self.perform(uri, headers:, timeout:, proxy:, max_bytes:, whitelist:, allow_private:)
    port = uri.port || (uri.scheme == "https" ? 443 : 80)

    connect_ip = nil
    unless proxy
      allowed, had_blocked = resolve_allowed(uri.host, whitelist, allow_private: allow_private)
      if allowed.empty?
        raise Error, "all resolved addresses for #{uri.host} are private, restricted, or not whitelisted" if had_blocked

        raise Error, "failed to resolve #{uri.host}"
      end
      connect_ip = allowed.first
    end

    http =
      if proxy
        p = URI.parse(proxy)
        Net::HTTP.new(uri.host, port, p.host, p.port, p.user, p.password)
      else
        Net::HTTP.new(uri.host, port)
      end
    http.use_ssl = uri.scheme == "https"
    http.ipaddr = connect_ip if connect_ip && http.respond_to?(:ipaddr=)
    http.open_timeout = 15
    http.read_timeout = timeout
    http.write_timeout = timeout if http.respond_to?(:write_timeout=)

    request = Net::HTTP::Get.new(uri.request_uri.empty? ? "/" : uri.request_uri)
    headers.each { |k, v| request[k] = v }
    request["Host"] ||= uri.host

    body = +""
    http.start do |session|
      session.request(request) do |response|
        response.read_body do |chunk|
          body << chunk
          if max_bytes && body.bytesize > max_bytes
            raise Error, "failed to read response: size exceeded #{max_bytes} bytes limit"
          end
        end
        return [response, body]
      end
    end
  rescue Error
    raise
  rescue SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, EOFError,
         Net::OpenTimeout, Net::ReadTimeout => e
    raise Error, "request failed: #{e.message}"
  end

  # Plain client (CreateHTTPClient port): proxy + timeout, no SSRF guards —
  # used by the search providers, which call fixed API endpoints. max_bytes
  # silently truncates (Go's io.LimitReader semantics).
  def self.plain_get(url, headers: {}, timeout: 10, proxy: nil, max_bytes: nil)
    plain_request(:get, url, headers: headers, timeout: timeout, proxy: proxy, max_bytes: max_bytes)
  end

  def self.plain_post(url, body:, headers: {}, timeout: 10, proxy: nil, max_bytes: nil)
    plain_request(:post, url, body: body, headers: headers, timeout: timeout, proxy: proxy, max_bytes: max_bytes)
  end

  def self.plain_request(method, url, body: nil, headers: {}, timeout: 10, proxy: nil, max_bytes: nil)
    uri = URI.parse(url.to_s)
    http =
      if proxy
        p = URI.parse(proxy)
        Net::HTTP.new(uri.host, uri.port, p.host, p.port, p.user, p.password)
      else
        Net::HTTP.new(uri.host, uri.port)
      end
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 15
    http.read_timeout = timeout
    http.write_timeout = timeout if http.respond_to?(:write_timeout=)

    request =
      if method == :post
        Net::HTTP::Post.new(uri.request_uri.empty? ? "/" : uri.request_uri)
      else
        Net::HTTP::Get.new(uri.request_uri.empty? ? "/" : uri.request_uri)
      end
    headers.each { |k, v| request[k] = v }
    request.body = body if body

    text = +""
    http.start do |session|
      session.request(request) do |response|
        response.read_body do |chunk|
          remaining = max_bytes ? max_bytes - text.bytesize : chunk.bytesize
          text << chunk.byteslice(0, remaining) if remaining.positive?
          return [response, text] if max_bytes && text.bytesize >= max_bytes
        end
        return [response, text]
      end
    end
  rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, EOFError,
         Net::OpenTimeout, Net::ReadTimeout => e
    raise Error, "request failed: #{e.message}"
  end
end
