# frozen_string_literal: true

require "json"
require "uri"
require "cgi"
require "fileutils"
require_relative "web_http"

# SkillRegistries — picoclaw's pkg/skills registry layer (clawhub_registry.go,
# github_registry.go, search_cache.go) + the installer's GitHub download flow.
module SkillRegistries
  CLAWHUB_TIMEOUT = 15
  MAX_RESPONSE_SIZE = 2 << 20

  # utils.ValidateSkillIdentifier port.
  def self.valid_identifier?(value)
    trimmed = value.to_s.strip
    return false if trimmed.empty?

    !(trimmed.include?("/") || trimmed.include?("\\") || trimmed.include?(".."))
  end

  # SearchCache port: exact hit else trigram-Jaccard >= 0.7 fuzzy hit; LRU;
  # max 50 entries; TTL 300s.
  class SearchCache
    SIMILARITY_THRESHOLD = 0.7

    def initialize(max_entries: 50, ttl_seconds: 300, now: nil)
      @max_entries = max_entries
      @ttl = ttl_seconds
      @now = now || -> { Time.now }
      @entries = {} # normalized query => { results:, trigrams:, stored_at: }
    end

    def get(query)
      normalized = normalize(query)
      evict_expired
      entry = @entries.delete(normalized) # LRU touch
      if entry
        @entries[normalized] = entry
        return entry[:results]
      end

      trigrams = trigrams(normalized)
      best = nil
      @entries.each_value do |candidate|
        sim = jaccard(trigrams, candidate[:trigrams])
        best = candidate if sim >= SIMILARITY_THRESHOLD && (best.nil? || sim > best[:sim])
        best[:sim] = sim if best && sim >= SIMILARITY_THRESHOLD && best[:sim].nil?
      end
      best && best[:sim] >= SIMILARITY_THRESHOLD ? best[:results] : nil
    end

    def put(query, results)
      normalized = normalize(query)
      @entries.delete(normalized)
      @entries[normalized] = { results: results, trigrams: trigrams(normalized), stored_at: @now.call }
      @entries.delete(@entries.first[0]) while @entries.size > @max_entries
      nil
    end

    def size = (@entries.size)

    private

    def normalize(query) = query.to_s.downcase.strip

    def evict_expired
      cutoff = @now.call - @ttl
      @entries.delete_if { |_, e| e[:stored_at] < cutoff }
    end

    def trigrams(text)
      padded = "  #{text}  "
      (0..padded.length - 3).map { |i| padded[i, 3] }.uniq.sort
    end

    def jaccard(a, b)
      return 1.0 if a.empty? && b.empty?
      return 0.0 if a.empty? || b.empty?

      (a & b).size.to_f / (a | b).size
    end
  end

  # ClawHub registry (https://clawhub.ai): /api/v1/search, /api/v1/skills/<slug>,
  # /api/v1/download?slug=&version=.
  class ClawHub
    NAME = "clawhub"

    def initialize(base_url: nil, auth_token: nil, proxy: nil)
      @base_url = base_url.to_s.empty? ? "https://clawhub.ai" : base_url
      @auth_token = auth_token.to_s.empty? ? nil : auth_token
      @proxy = proxy
    end

    def name = NAME

    def search(query, limit)
      params = { "q" => query }
      params["limit"] = limit.to_s if limit.positive?
      body = get("#{@base_url}/api/v1/search?#{URI.encode_www_form(params)}", accept: "application/json")
      JSON.parse(body)["results"].to_a.filter_map do |r|
        slug = r["slug"].to_s
        summary = r["summary"].to_s
        next if slug.empty? || summary.empty?

        { slug: slug, display_name: r["displayName"].to_s.empty? ? slug : r["displayName"],
          summary: summary, version: r["version"].to_s, score: r["score"].to_f, registry: NAME }
      end
    end

    def skill_meta(slug)
      body = get("#{@base_url}/api/v1/skills/#{URI.encode_uri_component(slug)}", accept: "application/json")
      resp = JSON.parse(body)
      { slug: resp["slug"], display_name: resp["displayName"], summary: resp["summary"],
        version: resp.dig("latestVersion", "version"),
        malware_blocked: resp.dig("moderation", "isMalwareBlocked") == true,
        suspicious: resp.dig("moderation", "isSuspicious") == true }
    end

    def download_and_install(slug, version, target_dir)
      raise "invalid slug #{slug.inspect}: identifier is required" unless SkillRegistries.valid_identifier?(slug)

      meta = begin
        skill_meta(slug)
      rescue StandardError
        nil # fallback: proceed without metadata
      end
      install_version = version.to_s.empty? ? (meta && meta[:version]) : version
      install_version = "latest" if install_version.to_s.empty?

      params = { "slug" => slug }
      params["version"] = install_version unless install_version == "latest"
      body = get("#{@base_url}/api/v1/download?#{URI.encode_www_form(params)}", accept: "application/zip")

      tmp = File.join(Dir.mktmpdir, "skill.zip")
      File.binwrite(tmp, body)
      SkillRegistries.extract_zip(tmp, target_dir)

      { version: install_version, summary: meta && meta[:summary],
        malware_blocked: meta && meta[:malware_blocked], suspicious: meta && meta[:suspicious] }
    end

    private

    def get(url, accept:)
      headers = { "Accept" => accept }
      headers["Authorization"] = "Bearer #{@auth_token}" if @auth_token
      response, body = WebHttp.plain_get(url, headers: headers, timeout: CLAWHUB_TIMEOUT,
                                              proxy: @proxy, max_bytes: MAX_RESPONSE_SIZE)
      code = response.code.to_i
      raise "HTTP #{code}: #{body}" unless (200..299).cover?(code)

      body
    end
  end

  # GitHub registry: code search for SKILL.md + contents-API install.
  class GitHub
    NAME = "github"

    def initialize(token: nil, api_base: nil, web_base: nil, raw_base: nil, proxy: nil)
      @token = token.to_s.empty? ? nil : token
      @api_base = api_base.to_s.empty? ? "https://api.github.com" : api_base
      @web_base = web_base.to_s.empty? ? "https://github.com" : web_base
      @raw_base = raw_base.to_s.empty? ? "https://raw.githubusercontent.com" : raw_base
      @proxy = proxy
    end

    def name = NAME

    def search(query, limit)
      query = query.to_s.strip
      return [] if query.empty?

      limit = 5 if limit <= 0
      params = URI.encode_www_form("q" => "#{query} filename:SKILL.md", "per_page" => limit.to_s)
      headers = { "Accept" => "application/vnd.github+json" }
      headers["Authorization"] = "Bearer #{@token}" if @token
      response, body = WebHttp.plain_get("#{@api_base}/search/code?#{params}", headers: headers,
                                              timeout: CLAWHUB_TIMEOUT, proxy: @proxy, max_bytes: MAX_RESPONSE_SIZE)
      code = response.code.to_i
      if !@token && ((code == 401 && body.downcase.include?("requires authentication")) ||
                     (code == 403 && body.downcase.include?("rate limit exceeded")))
        warn "github skills search: unauthenticated request rejected; configure a token"
        return []
      end
      raise "github search failed: HTTP #{code}: #{body}" unless (200..299).cover?(code)

      by_slug = {}
      JSON.parse(body)["items"].to_a.each do |item|
        slug = github_slug(item)
        next if slug.nil?

        result = { slug: slug, display_name: item.dig("repository", "name").to_s,
                   summary: item.dig("repository", "description").to_s.strip,
                   version: item.dig("repository", "default_branch").to_s.strip,
                   score: item["score"].to_f, registry: NAME }
        by_slug[slug] = result if by_slug[slug].nil? || by_slug[slug][:score] < result[:score]
      end
      by_slug.values.sort_by { |r| [-r[:score], r[:slug]] }.first(limit)
    end

    # slug for code-search items: "<owner>/<repo>/<skill-dir>" derived from the
    # SKILL.md path (root SKILL.md → owner/repo).
    def github_slug(item)
      repo = item.dig("repository", "full_name").to_s
      return nil if repo.empty?

      path = item["path"].to_s # e.g. "skills/foo/SKILL.md" or "SKILL.md"
      dir = File.dirname(path)
      dir == "." ? repo : "#{repo}/#{dir}"
    end

    # target: "owner/repo[/sub/path][@ref]". Installs via the contents API
    # (root: SKILL.md only; subdirs limited to skill resource dirs).
    def download_and_install(target, version, target_dir)
      owner, repo, sub_path, ref = parse_target(target)
      ref = version.to_s.empty? ? (ref || default_branch(owner, repo)) : version
      sub_path = File.dirname(sub_path) == "." ? "" : File.dirname(sub_path) if sub_path.end_with?("SKILL.md")

      api_path = ["repos", owner, repo, "contents", *sub_path.to_s.split("/").reject(&:empty?)].join("/")
      install_dir(api_path, ref, target_dir, root: true)
      raise "SKILL.md not found in repository" unless File.exist?(File.join(target_dir, "SKILL.md"))

      { version: ref, summary: nil, malware_blocked: false, suspicious: false }
    end

    def resolve_dir_name(target)
      owner, repo, sub_path, = parse_target(target)
      [owner, repo, *sub_path.to_s.split("/")].reject(&:empty?).join("-")
    end

    private

    def parse_target(target)
      raw = target.to_s.sub(%r{\Ahttps?://(www\.)?github\.com/}, "").sub(%r{/(tree|blob)/}, "/")
      raw, ref = raw.split("@", 2)
      parts = raw.split("/").reject(&:empty?)
      raise "invalid GitHub target #{target.inspect}" if parts.size < 2

      [parts[0], parts[1], parts[2..]&.join("/"), ref]
    end

    def default_branch(owner, repo)
      body = api_get("#{@api_base}/repos/#{owner}/#{repo}")
      JSON.parse(body)["default_branch"].to_s.empty? ? "main" : JSON.parse(body)["default_branch"]
    end

    def install_dir(api_path, ref, local_dir, root:)
      body = api_get("#{@api_base}/#{api_path}?ref=#{CGI.escape(ref)}")
      JSON.parse(body).each do |item|
        local_path = File.join(local_dir, item["name"])
        case item["type"]
        when "file"
          next if root && item["name"] != "SKILL.md"

          download_file(item["download_url"], local_path)
        when "dir"
          next unless %w[scripts references assets templates docs].include?(item["name"])

          install_dir(item["url"].sub(@api_base + "/", "").split("?").first, ref, local_path, root: false)
        end
      end
    end

    def api_get(url)
      headers = { "Accept" => "application/vnd.github+json" }
      headers["Authorization"] = "Bearer #{@token}" if @token
      response, body = WebHttp.plain_get(url, headers: headers, timeout: CLAWHUB_TIMEOUT,
                                              proxy: @proxy, max_bytes: MAX_RESPONSE_SIZE)
      raise "HTTP #{response.code}" unless response.code.to_i == 200

      body
    end

    def download_file(url, local_path)
      FileUtils.mkdir_p(File.dirname(local_path))
      _response, body = WebHttp.plain_get(url, timeout: CLAWHUB_TIMEOUT, proxy: @proxy)
      File.binwrite(local_path, body)
    end
  end

  # Minimal ZIP extraction (stored + deflated entries) — enough for registry
  # skill archives; avoids shelling out.
  def self.extract_zip(zip_path, target_dir)
    require "zlib"
    data = File.binread(zip_path)
    pos = 0
    FileUtils.mkdir_p(target_dir)
    while (sig = data[pos, 4]) == "PK\x03\x04".b
      fields = data[pos, 30].unpack("v v v v v V V V v v")
      _method_flags = fields[1]
      method = fields[3]
      compressed_size = fields[6]
      name_len = fields[9]
      extra_len = fields[10]
      name = data[(pos + 30), name_len]
      body = data[(pos + 30 + name_len + extra_len), compressed_size]
      content = method == 8 ? Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(body) : body
      out = File.join(target_dir, name)
      if name.end_with?("/")
        FileUtils.mkdir_p(out)
      else
        FileUtils.mkdir_p(File.dirname(out))
        File.binwrite(out, content)
      end
      pos += 30 + name_len + extra_len + compressed_size
    end
    raise "not a zip archive" if pos.zero?
  end
end
