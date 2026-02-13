WS_TOKEN = ENV['SUPERVISOR_TOKEN']
WS_URL   = "ws://supervisor/core/api/websocket"
TCP_PORT = (ENV['TCP_PORT'] || '8080').to_i

require 'socket'
require 'json'
require 'faye/websocket'
require 'eventmachine'

# ---------------------------
# Parsing / updates to Savant
# ---------------------------
module HassMessageParsingMethods
  def new_data(js_data)
    return {} unless js_data['data']
    js_data['data']['new_state'] || js_data['data']
  end

  def parse_event(js_data)
    return entities_changed(js_data['c']) if js_data.is_a?(Hash) && js_data.keys == ['c']
    return entities_changed(js_data['a']) if js_data.is_a?(Hash) && js_data.keys == ['a']

    case js_data['event_type']
    when 'state_changed' then parse_state(new_data(js_data))
    when 'call_service'  then parse_service(new_data(js_data))
    else
      [:unknown, js_data['event_type']]
    end
  end

  def entities_changed(entities)
    entities.each do |entity, state|
      state = state['+'] if state.is_a?(Hash) && state.key?('+')
      attributes = state['a']
      value      = state['s']
      update?("#{entity}_state", 'state', value) if value
      update_with_hash(entity, attributes) if attributes
    end
  end

  def parse_service(data)
    return [] unless data['service_data'] && data['service_data']['entity_id']
    [data['service_data']['entity_id']].flatten.compact.map do |entity|
      "type:call_service,entity:#{entity},service:#{data['service']},domain:#{data['domain']}"
    end
  end

  def included_with_filter?(primary_key)
    return true if @filter.nil? || @filter.empty? || @filter == ['all']
    @filter.include?(primary_key)
  end

  def parse_state(message)
    eid = message['entity_id']
    update?("#{eid}_state", 'state', message['state']) if eid

    atr = message['attributes']
    case atr
    when Hash  then update_with_hash(eid, atr)
    when Array then update_with_array(eid, atr)
    end
  end

  def update?(key, primary_key, value)
    return unless value && included_with_filter?(primary_key)
    # fix HA brightness 1/2 edge
    value = 3 if primary_key == 'brightness' && [1, 2].include?(value)
    send_line("#{key}===#{value}")
    cache_line("#{key}===#{value}")
  end

  def update_hashed_array(parent_key, msg_array)
    msg_array.each_with_index do |e, i|
      key = "#{parent_key}_#{i}"
      case e
      when Hash  then update_with_hash(key, e)
      when Array then update_with_array(key, e)
      else
        update?(key, i, e)
      end
    end
  end

  def update_with_array(parent_key, msg_array)
    return update_hashed_array(parent_key, msg_array) if msg_array.first.is_a?(Hash)
    update?(parent_key, parent_key, msg_array.join(','))
  end

  def update_with_hash(parent_key, msg_hash)
    arr = msg_hash.map do |k, v|
      update?("#{parent_key}_#{k}", k, v) if included_with_filter?(k)
      "#{k}:#{v}"
    end
    return unless included_with_filter?('attributes')
    update?("#{parent_key}_attributes", parent_key, arr.join(','))
  end

  def parse_result(js_data)
    res = js_data['result']
    return unless res
    return parse_state(res) unless res.is_a?(Array)
    res.each { |e| parse_state(e) }
  end
end

# ---------------------------
# Requests from Savant to HA
# ---------------------------
module HassRequests
  def send_data(**data)
    send_json(data)
  end

  def fan_on(entity_id, speed)
    send_data(type: :call_service, domain: :fan, service: :turn_on,
              service_data: { speed: speed }, target: { entity_id: entity_id })
  end
  def fan_off(entity_id, _speed=nil)
    send_data(type: :call_service, domain: :fan, service: :turn_off, target: { entity_id: entity_id })
  end
  def fan_set(entity_id, speed)
    speed.to_i.zero? ? fan_off(entity_id) : fan_on(entity_id, speed)
  end

  def dimmer_set(entity_id, level)
    level = level.to_i
    send_data(type: :call_service, domain: :light, service: (level.zero? ? :turn_off : :turn_on),
              service_data: (level.zero? ? {} : { brightness_pct: level }),
              target: { entity_id: entity_id })
  end

  def socket_on(entity_id)
    send_data(type: :call_service, domain: :switch, service: :turn_on, target: { entity_id: entity_id })
  end
  def socket_off(entity_id)
    send_data(type: :call_service, domain: :switch, service: :turn_off, target: { entity_id: entity_id })
  end

  def shade_set(entity_id, level)
    send_data(type: :call_service, domain: :cover, service: :set_cover_position,
              service_data: { position: level.to_i }, target: { entity_id: entity_id })
  end

  def lock_lock(entity_id)
    send_data(type: :call_service, domain: :lock, service: :lock, target: { entity_id: entity_id })
  end
  def unlock_lock(entity_id)
    send_data(type: :call_service, domain: :lock, service: :unlock, target: { entity_id: entity_id })
  end

  def open_garage_door(entity_id)
    send_data(type: :call_service, domain: :cover, service: :open_cover, target: { entity_id: entity_id })
  end
  def close_garage_door(entity_id)
    send_data(type: :call_service, domain: :cover, service: :close_cover, target: { entity_id: entity_id })
  end
  def toggle_garage_door(entity_id)
    send_data(type: :call_service, domain: :cover, service: :toggle, target: { entity_id: entity_id })
  end

  def button_press(entity_id)
    send_data(type: :call_service, domain: :button, service: :press, target: { entity_id: entity_id })
  end
end

# -------------------------------------------------------
# HassCore: 1 HA WebSocket + TCP server + hot-swap client
# -------------------------------------------------------
class HassCore
  include HassMessageParsingMethods
  include HassRequests

  STATE_FILE          = ENV['STATE_FILE'] || '/data/savant_hass_proxy_state.json'
  HA_PING_INTERVAL    = (ENV['HA_PING_INTERVAL'] || '30').to_i
  TCP_HEARTBEAT_SECS  = (ENV['TCP_HEARTBEAT_SECS'] || '1').to_i
  RECONNECT_MIN       = (ENV['HA_RECONNECT_MIN'] || '1').to_i
  RECONNECT_MAX       = (ENV['HA_RECONNECT_MAX'] || '30').to_i
  WS_QUEUE_MAX        = (ENV['WS_QUEUE_MAX'] || '200').to_i
  CACHE_MAX_LINES     = (ENV['CACHE_MAX_LINES'] || '200').to_i

  def initialize(ws_url, token)
    @ws_url  = ws_url
    @token   = token

    @shutdown = false
    @ha_authed = false
    @id = 0
    @ws_queue = []
    @reconnect_delay = RECONNECT_MIN
    @ha_ping_timer_started = false

    @client = nil
    @client_mutex = Mutex.new
    @client_writer_mutex = Mutex.new

    @cache = []
    @cache_mutex = Mutex.new

    @persisted = load_state
    @filter = ['all']
    apply_persisted_defaults

    @em_mutex = Mutex.new
    ensure_em_running
    connect_websocket
    start_tcp_heartbeat
  end

  # ---------------- TCP Server side ----------------
  def attach_client(sock)
    setup_tcp_keepalive(sock)

    # Debounce: Savant sometimes opens sockets in bursts
    now = Time.now.to_f
    @last_attach ||= 0.0
    if (now - @last_attach) < 0.25
      safe_close_socket(sock)
      return
    end
    @last_attach = now

    old = nil
    @client_mutex.synchronize do
      old = @client
      @client = sock
    end
    safe_close_socket(old) if old

    p([:info, :client_connected, sock.peeraddr])

    # Always talk first so Savant marks it "Connected"
    send_line("heartbeat===1")
    send_line("ready===ok") if @ha_authed
    replay_cache

    start_client_reader_thread(sock)
  end

  def detach_client(sock)
    # IMPORTANT: no recursive locking
    old = nil
    @client_mutex.synchronize do
      if @client == sock
        old = @client
        @client = nil
      end
    end
    safe_close_socket(old) if old
  end

  def send_line(line)
    sock = nil
    @client_mutex.synchronize { sock = @client }
    return unless sock && !sock.closed?

    @client_writer_mutex.synchronize do
      begin
        sock.write(line.to_s)
        sock.write("\n")
      rescue => e
        p([:error, :tcp_write_failed, e.message])
        detach_client(sock)
      end
    end
  end

  def cache_line(line)
    @cache_mutex.synchronize do
      @cache << line
      @cache.shift while @cache.length > CACHE_MAX_LINES
    end
  end

  def replay_cache
    lines = nil
    @cache_mutex.synchronize { lines = @cache.dup }
    p([:info, :replayed_cache, lines.length])
    lines.each { |l| send_line(l) }
  end

  def start_client_reader_thread(sock)
    Thread.new do
      begin
        while (raw = sock.gets)
          line = raw.chomp
          from_savant(line)
        end
      rescue => e
        p([:error, :savant_read_error, e.class.to_s, e.message])
      ensure
        detach_client(sock)
      end
    end
  end

  def start_tcp_heartbeat
    Thread.new do
      loop do
        break if @shutdown
        send_line("heartbeat===1")
        sleep TCP_HEARTBEAT_SECS
      end
    end
  end

  # ---------------- Savant command parsing ----------------
  def from_savant(req)
    cmd, *params = req.split(',')
    cmd = cmd.to_s.strip

    # ACK inmediato para que Savant no marque "Not Connected"
    # (Aunque response_required="no", esto ayuda al estado de enlace)
    case cmd
    when 'state_filter'
      @filter = params.flatten.compact.reject(&:empty?)
      @persisted['filter'] = @filter
      save_state
      send_line("state_filter===ok")
      return
    when 'subscribe_entity'
      entities = params.join(',').split(',').map(&:strip).reject(&:empty?)
      @persisted['entities'] = entities
      save_state
      send_line("subscribe_entity===ok")
      send_json(type: 'subscribe_entities', entity_ids: entities) unless entities.empty?
      return
    when 'subscribe_events'
      send_line("subscribe_events===ok")
      send_json(type: 'subscribe_events')
      return
    when 'ping'
      send_line("pong===1")
      return
    end

    # comandos tipo acción (dimmer_set, socket_on, etc.)
    if HassRequests.instance_methods(false).include?(cmd.to_sym)
      send_line("#{cmd}===ok")
      send(cmd, *params)
    else
      send_line("unknown_cmd===#{cmd}")
      p([:error, :unknown_cmd, cmd, req])
    end
  end

  # ---------------- HA WebSocket side ----------------
  def ensure_em_running
    return if EM.reactor_running?
    @em_mutex.synchronize do
      return if EM.reactor_running?
      Thread.new { EM.run }
    end
    50.times { break if EM.reactor_running?; sleep 0.05 }
  end

  def connect_websocket
    EM.schedule { start_ws }
  end

  def start_ws
    return if @shutdown
    @ha_authed = false
    @hass_ws = Faye::WebSocket::Client.new(@ws_url)

    @hass_ws.on :open do
      p([:debug, :ws_connected])
      @reconnect_delay = RECONNECT_MIN
    end

    @hass_ws.on :message do |event|
      handle_ws_message(event.data)
    end

    @hass_ws.on :close do |event|
      p([:debug, :ws_disconnected, event.code, event.reason])
      @hass_ws = nil
      schedule_reconnect
    end

    @hass_ws.on :error do |event|
      p([:error, :ws_error, event.message])
    end
  end

  def schedule_reconnect
    return if @shutdown
    delay = @reconnect_delay
    @reconnect_delay = [@reconnect_delay * 2, RECONNECT_MAX].min
    p([:info, :ws_reconnect_scheduled, delay])
    EM.add_timer(delay) { start_ws }
  end

  def can_send_ws?
    @hass_ws && @hass_ws.ready_state == Faye::WebSocket::API::OPEN
  rescue
    false
  end

  def enqueue_ws(json)
    @ws_queue << json
    @ws_queue.shift while @ws_queue.length > WS_QUEUE_MAX
  end

  def flush_ws_queue
    return unless @ha_authed && can_send_ws?
    while (msg = @ws_queue.shift)
      @hass_ws.send(msg)
    end
    p([:info, :ws_queue_flushed])
  end

  def start_ha_ping
    return if @ha_ping_timer_started
    @ha_ping_timer_started = true
    EM.add_periodic_timer(HA_PING_INTERVAL) do
      next if @shutdown
      send_json(type: 'ping')
    end
  end

  def handle_ws_message(data)
    msg = JSON.parse(data) rescue nil
    return unless msg

    case msg['type']
    when 'auth_required'
      safe_ws_send({ type: 'auth', access_token: @token }.to_json)
    when 'auth_ok'
      @ha_authed = true
      p([:info, :ha_ready])
      start_ha_ping
      # restore entities
      ents = (@persisted['entities'].is_a?(Array) ? @persisted['entities'] : [])
      send_json(type: 'subscribe_entities', entity_ids: ents) unless ents.empty?
      flush_ws_queue
      send_line("ready===ok")
    when 'event'
      parse_event(msg['event'])
    when 'result'
      parse_result(msg)
    when 'pong'
      p([:debug, :pong_received])
    end
  end

  def send_json(hash)
    @id += 1
    hash['id'] = @id
    json = hash.to_json

    if @ha_authed && can_send_ws?
      safe_ws_send(json)
    else
      enqueue_ws(json)
    end
  end

  def safe_ws_send(json)
    EM.schedule do
      if can_send_ws?
        @hass_ws.send(json)
      else
        enqueue_ws(json)
      end
    end
  end

  # ---------------- State persistence ----------------
  def load_state
    JSON.parse(File.read(STATE_FILE)) rescue { 'filter' => nil, 'entities' => [] }
  end

  def save_state
    dir = File.dirname(STATE_FILE)
    Dir.mkdir(dir) unless Dir.exist?(dir)
    File.write(STATE_FILE, @persisted.to_json)
  rescue => e
    p([:error, :state_save_failed, e.message])
  end

  def apply_persisted_defaults
    if @persisted['filter'].is_a?(Array) && !@persisted['filter'].empty?
      @filter = @persisted['filter']
      p([:info, :filter_restored, @filter])
    end
  end

  # ---------------- Socket opts ----------------
  def setup_tcp_keepalive(sock)
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
    if Socket.const_defined?(:IPPROTO_TCP)
      sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPIDLE, 30) if Socket.const_defined?(:TCP_KEEPIDLE)
      sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPINTVL, 10) if Socket.const_defined?(:TCP_KEEPINTVL)
      sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPCNT, 3) if Socket.const_defined?(:TCP_KEEPCNT)
    end
  rescue => e
    p([:debug, :keepalive_not_set, e.message])
  end

  def safe_close_socket(sock)
    return unless sock
    begin
      sock.close unless sock.closed?
    rescue
    end
  end
end

# -------------
# TCP Server
# -------------
Thread.abort_on_exception = true

core = HassCore.new(WS_URL, WS_TOKEN)

server = TCPServer.new(TCP_PORT)
server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
p([:info, :server_started, TCP_PORT])

loop do
  client = server.accept
  core.attach_client(client)
end
