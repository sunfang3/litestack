# frozen_string_literal: true

require "rack"
require "tilt"
require "erubi"
require "json"
require "cgi"
require "uri"

require_relative "../../litestack/litemetric"

class Liteboard
  class BadRequestError < StandardError; end
  class RenderError < StandardError; end
  class NotFoundError < StandardError; end

  SECURITY_HEADERS = {
    "content-type" => "text/html; charset=utf-8",
    "cache-control" => "no-cache",
    "x-content-type-options" => "nosniff",
    "referrer-policy" => "no-referrer",
    "x-frame-options" => "DENY",
    "content-security-policy" => "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'"
  }.freeze

  @@resolutions = {"minute" => [300, 12], "hour" => [3600, 24], "day" => [3600 * 24, 7], "week" => [3600 * 24 * 7, 53], "year" => [3600 * 24 * 365, 100]}
  @@res_mapping = {"hour" => "minute", "day" => "hour", "week" => "day", "year" => "week"}
  @@templates = {}

  TOPIC_ROUTES = {
    "/topics/Litejob" => :litejob,
    "/topics/Litecache" => :litecache,
    "/topics/Litedb" => :litedb,
    "/topics/Litecable" => :litecable
  }.freeze

  @@app = proc do |env|
    Liteboard.dispatch(env)
  end

  def self.dispatch(env)
    path = env["PATH_INFO"].to_s
    case path
    when "/"
      new(env).call(:index)
    when %r{\A/assets/(liteboard\.(css|js))\z}
      serve_asset(Regexp.last_match(1))
    when *TOPIC_ROUTES.keys
      new(env).call(TOPIC_ROUTES[path])
    else
      new(env).error_response(404, "Not found", "No page for #{h(path)}. Try the home page.")
    end
  rescue BadRequestError => e
    new(env).error_response(400, "Bad request", e.message)
  rescue
    new(env).error_response(500, "Render error", "Something went wrong rendering this page.")
  end

  def self.serve_asset(name)
    root = File.join(__dir__, "assets")
    path = File.expand_path(File.join(root, name))
    return [404, SECURITY_HEADERS.merge("content-type" => "text/plain"), ["Not found"]] unless path.start_with?(root) && File.file?(path)

    body = File.binread(path)
    type = name.end_with?(".css") ? "text/css; charset=utf-8" : "application/javascript; charset=utf-8"
    [200, SECURITY_HEADERS.merge("content-type" => type, "cache-control" => "public, max-age=3600"), [body]]
  end

  def self.h(text)
    CGI.escapeHTML(text.to_s)
  end

  def self.app
    @@app
  end

  def initialize(env)
    @env = env
    @req = Rack::Request.new(@env)
    @params = @req.params
    @running = true
    @lm = Litemetric.instance
    @error_title = nil
    @error_message = nil
  end

  def params(key)
    URI.decode_uri_component(@params[key.to_s].to_s)
  rescue ArgumentError
    raise BadRequestError, "Invalid parameter encoding for #{key}"
  end

  def call(method)
    before
    res = send(method)
    after(res)
  rescue BadRequestError => e
    error_response(400, "Bad request", e.message)
  rescue NotFoundError => e
    error_response(404, "Not found", e.message)
  rescue => e
    @logger&.error { e.full_message } if defined?(@logger)
    error_response(500, "Render error", "Failed to render #{method}. Check metrics database connectivity.")
  end

  def after(body = nil)
    [200, SECURITY_HEADERS.dup, [body.to_s]]
  end

  def error_response(status, title, message)
    @error_title = title
    @error_message = message
    body = render(:error)
    [status, SECURITY_HEADERS.dup, [body]]
  rescue
    html = "<!doctype html><html><body><main><h1>#{self.class.h(title)}</h1><p>#{self.class.h(message)}</p><p><a href='/'>Home</a></p></main></body></html>"
    [status, SECURITY_HEADERS.dup, [html]]
  end

  def before
    @res = params(:res)
    @res = "day" if @res.nil? || @res == ""
    @resolution = @@res_mapping[@res]
    unless @resolution
      @res = "day"
      @resolution = @@res_mapping[@res]
    end
    @step = @@resolutions[@resolution][0]
    @count = @@resolutions[@resolution][1]
    @order = params(:order)
    @order = nil if @order == ""
    @dir = params(:dir)
    @dir = "desc" if @dir.nil? || @dir == ""
    @dir = @dir.downcase
    @idir = (@dir == "asc") ? "desc" : "asc"
    @search = params(:search)
    @search = nil if @search == ""
    @topics = safe_topics
  end

  def safe_topics
    @lm.topic_summaries(@resolution, @step * @count, @order || "topic", @dir, @search)
  rescue
    []
  end

  def index
    @order ||= "topic"
    @empty_state = @topics.nil? || @topics.empty?
    @topics.each do |topic|
      data_points = begin
        @lm.topic_data_points(@step, @count, @resolution, topic[0])
      rescue
        []
      end
      topic << data_points.collect { |r| [r[0], r[2] || 0] }
    end
    render :index
  end

  def litecache
    component_page("Litecache") do
      @order ||= "rcount"
      @topic = "Litecache"
      @events = events_for(@topic)
      enrich_events_with_counts_and_values!
      @snapshot = read_snapshot(@topic)
      @size = snap_dig(@snapshot, :size, 0)
      @max_size = snap_dig(@snapshot, :max_size, 0)
      @full = (@max_size.to_f > 0) ? ((@size.to_f / @max_size.to_f) * 100) : 0
      @entries = snap_dig(@snapshot, :entries, 0)
      @gets = @events.find { |t| t["name"] == "get" }
      @sets = @events.find { |t| t["name"] == "set" }
      @reads = @gets ? @gets["rcount"].to_i : 0
      @writes = @sets ? @sets["rcount"].to_i : 0
      @hitrate = @gets ? @gets["ravg"].to_f : 0
      @hits = @reads * @hitrate
      @misses = @reads - @hits
      @reads_vs_writes = zip_counts(@gets, @sets)
      @hits_vs_misses = hit_miss_series(@gets)
      @top_reads = keys_for(@topic, "get")
      @top_writes = keys_for(@topic, "set")
      @empty_state = @events.empty? && @entries.to_i.zero?
      render :litecache
    end
  end

  def litedb
    component_page("Litedb") do
      @order ||= "rcount"
      @topic = "Litedb"
      @events = events_for(@topic)
      enrich_events_for_db!
      @snapshot = read_snapshot(@topic)
      @size = snap_dig(@snapshot, :size, 0)
      @tables = snap_dig(@snapshot, :tables, 0)
      @indexes = snap_dig(@snapshot, :indexes, 0)
      @gets = @events.find { |t| t["name"] == "Read" }
      @sets = @events.find { |t| t["name"] == "Write" }
      @reads = @gets ? @gets["rcount"].to_i : 0
      @writes = @sets ? @sets["rcount"].to_i : 0
      @time = @gets ? @gets["ravg"].to_f : 0
      @reads_vs_writes = zip_counts(@gets, @sets)
      @reads_vs_writes_times = zip_values(@gets, @sets)
      @read_times = @gets ? @gets["rtotal"].to_f : 0
      @write_times = @sets ? @sets["rtotal"].to_f : 0
      @slowest = (keys_for(@topic, "Read", "ravg") + keys_for(@topic, "Write", "ravg")).sort_by { |a| a["ravg"].to_f }.last(8).reverse
      @popular = (keys_for(@topic, "Read", "rtotal") + keys_for(@topic, "Write", "rtotal")).sort_by { |a| a["rtotal"].to_f }.last(8).reverse
      @empty_state = @events.empty?
      render :litedb
    end
  end

  def litejob
    component_page("Litejob") do
      @order ||= "rcount"
      @topic = "Litejob"
      @events = events_for(@topic)
      @events.each do |event|
        data_points = begin
          @lm.event_data_points(@step, @count, @resolution, @topic, event["name"] || event[:name])
        rescue
          []
        end
        event["counts"] = data_points.collect { |r| [r["rtime"], r["rcount"] || 0] }
        event["values"] = data_points.collect { |r| [r["rtime"], r["rtotal"] || 0.0] }
      end
      @snapshot = read_snapshot(@topic)
      @size = snap_dig(@snapshot, :size, 0)
      @jobs = snap_dig(@snapshot, :jobs, 0)
      @queues = begin
        @snapshot[0] && @snapshot[0][:queues]
      rescue
        {}
      end || {}
      @processed_jobs = @events.find { |e| e["name"] == "perform" }
      @processed_count = @processed_jobs ? @processed_jobs["rcount"].to_i : 0
      @processing_time = @processed_jobs ? @processed_jobs["rtotal"].to_f : 0
      keys_summaries = keys_for(@topic, "perform")
      @processed_count_by_queue = keys_summaries.collect { |r| [r["key"], r["rcount"]] }
      @processing_time_by_queue = keys_summaries.collect { |r| [r["key"], r["rtotal"]] }
      @processed_count_over_time = @processed_jobs ? (@processed_jobs["counts"] || []) : []
      @processing_time_over_time = @processed_jobs ? (@processed_jobs["values"] || []) : []
      @processed_count_over_time_by_queues = [["Time"]]
      @processing_time_over_time_by_queues = [["Time"]]
      @empty_state = @events.empty? && @jobs.to_i.zero?
      render :litejob
    end
  end

  def litecable
    component_page("Litecable") do
      @order ||= "rcount"
      @topic = "Litecable"
      @events = events_for(@topic)
      @events.each do |event|
        data_points = begin
          @lm.event_data_points(@step, @count, @resolution, @topic, event["name"])
        rescue
          []
        end
        event["counts"] = data_points.collect { |r| [r["rtime"], r["rcount"] || 0] }
      end
      @subscription_count = event_count("subscribe")
      @broadcast_count = event_count("broadcast")
      @message_count = event_count("message")
      @subscriptions_over_time = event_series("subscribe")
      @broadcasts_over_time = event_series("broadcast")
      @messages_over_time = event_series("message")
      @messages_over_time = @messages_over_time.collect.with_index { |msg, i| [msg[0], (@broadcasts_over_time[i] && @broadcasts_over_time[i][1]) || 0, msg[1]] }
      @top_subscribed_channels = keys_for(@topic, "subscribe")
      @top_messaged_channels = keys_for(@topic, "message")
      @empty_state = @events.empty?
      render :litecable
    end
  end

  def index_url
    "/?res=#{encode(@res)}&order=#{encode(@order)}&dir=#{encode(@dir)}&search=#{encode(@search)}"
  end

  def topic_url(topic)
    "/topics/#{encode(topic)}?res=#{encode(@res)}&order=#{encode(@order)}&dir=#{encode(@dir)}&search=#{encode(@search)}"
  end

  def index_sort_url(field)
    "/?#{compose_query(field)}"
  end

  def topic_sort_url(field)
    "/topics/#{encode(@topic)}?#{compose_query(field)}"
  end

  def event_sort_url(field)
    "/topics/#{encode(@topic)}/events/#{encode(@event)}?#{compose_query(field)}"
  end

  def compose_query(field)
    field = field.to_s.downcase
    "res=#{encode(@res)}&order=#{encode(field)}&dir=#{encode((@order == field) ? @idir : @dir)}&search=#{encode(@search)}"
  end

  def sorted?(field)
    @order == field
  end

  def dir(field)
    if sorted?(field)
      if @dir == "asc"
        return "<span class='sort-indicator' aria-label='sorted ascending'>▲</span>"
      else
        return "<span class='sort-indicator' aria-label='sorted descending'>▼</span>"
      end
    end
    "&nbsp;&nbsp;"
  end

  def encode(text)
    URI.encode_uri_component(text.to_s)
  end

  def h(text)
    self.class.h(text)
  end

  def json_data(obj)
    JSON.generate(obj)
  rescue
    "[]"
  end

  def round(float)
    return 0 unless float.is_a? Numeric
    (float * 100).round.to_f / 100
  end

  def format(float)
    float = float.to_f.round(3)
    string = float.to_s
    whole, decimal = string.split(".")
    whole = whole.chars.reverse.each_slice(3).map(&:join).join(",").reverse
    whole = [whole, decimal].join(".") if decimal
    whole
  end

  private

  def component_page(name)
    yield
  end

  def events_for(topic)
    @lm.events_summaries(topic, @resolution, @order || "rcount", @dir, @search, @step * @count)
  rescue
    []
  end

  def keys_for(topic, event, order = nil)
    @lm.keys_summaries(topic, event, @resolution, order || @order || "rcount", @dir, nil, @step * @count).first(8)
  rescue
    []
  end

  def event_count(name)
    ev = @events.find { |t| t["name"] == name }
    ev ? ev["rcount"].to_i : 0
  end

  def event_series(name)
    ev = @events.find { |t| t["name"] == name }
    ev ? (ev["counts"] || []) : []
  end

  def enrich_events_with_counts_and_values!
    @events.each do |event|
      data_points = begin
        @lm.event_data_points(@step, @count, @resolution, @topic, event["name"])
      rescue
        []
      end
      event["counts"] = data_points.collect { |r| [r["rtime"], r["rcount"]] }
      event["values"] = data_points.collect { |r| [r["rtime"], r["ravg"]] }
    end
  end

  def enrich_events_for_db!
    @events.each do |event|
      data_points = begin
        @lm.event_data_points(@step, @count, @resolution, @topic, event["name"])
      rescue
        []
      end
      event["counts"] = data_points.collect { |r| [r["rtime"], r["rcount"] || 0] }
      event["values"] = data_points.collect { |r| [r["rtime"], r["rtotal"] || 0] }
    end
  end

  def zip_counts(gets, sets)
    return [] unless gets && sets && gets["counts"] && sets["counts"]
    gets["counts"].collect.with_index { |obj, i| obj.clone << (sets["counts"][i] && sets["counts"][i][1]).to_i }
  rescue
    []
  end

  def zip_values(gets, sets)
    return [] unless gets && sets && gets["values"] && sets["values"]
    gets["values"].collect.with_index { |obj, i| [obj[0], obj[1], (sets["values"][i] && sets["values"][i][1]).to_f] }
  rescue
    []
  end

  def hit_miss_series(gets)
    return [] unless gets && gets["values"] && gets["counts"]
    gets["values"].collect.with_index { |obj, i| [obj[0], obj[1].to_f * gets["counts"][i][1].to_f, (1 - obj[1].to_f) * gets["counts"][i][1].to_f] }
  rescue
    []
  end

  def snap_dig(snapshot, key, default)
    return default if snapshot.nil? || snapshot.empty? || snapshot[0].nil?
    summary = snapshot[0][:summary] || snapshot[0]["summary"]
    return default unless summary
    summary[key] || summary[key.to_s] || default
  rescue
    default
  end

  def read_snapshot(topic)
    snapshot = @lm.snapshot(topic)
    if snapshot.nil? || snapshot.empty?
      []
    else
      snapshot[0] = Oj.load(snapshot[0]) if snapshot[0].is_a?(String)
      snapshot
    end
  rescue
    []
  end

  def render(tpl_name)
    layout = Tilt.new(File.join(__dir__, "views/layout.erb"), default_encoding: "UTF-8")
    tpl_path = File.join(__dir__, "views/#{tpl_name}.erb")
    raise RenderError, "Missing template #{tpl_name}" unless File.file?(tpl_path)
    tpl = Tilt.new(tpl_path, default_encoding: "UTF-8")
    layout.render(self) { tpl.render(self) }
  end
end
