WS_TOKEN = ENV['SUPERVISOR_TOKEN']
WS_URL   = "ws://supervisor/core/api/websocket"
TCP_PORT = (ENV['TCP_PORT'] || '8080').to_i

require 'socket'
require 'json'
require 'faye/websocket'
require 'eventmachine'

module HassMessageParsingMethods
  def new_data(js_data)
    return {} unless js_data['data']
    js_data['data']['new_state'] || js_data['data']
  end

  def parse_event(js_data)
    return entities_changed(js_data['c']) if js_data.keys == ['c']
    return entities_changed(js_data['a']) if js_data.keys == ['a']

    case js_data['event_type']
    when 'state_changed' then parse_state(new_data(js_data))
    when 'call_service'  then parse_service(new_data(js_data))
    else
      [:unknown, js_data['event_type']]
    end
  end

  def entities_changed(entities)
    entities.each do |entity, state|
      state = state['+'] if state.key?('+')
      attributes = state['a']
      value = state['s']
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
    return true if @filter.empty? || @filter == ['all']
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
    value = 3 if primary_key == 'brightness' && [1, 2].include?(value)
    send_to_savant("#{key}===#{value}")
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

module HassRequests
  def send_data(**data)
    send_json(data)
  end

  def fan_on(entity_id, speed)
    send_data(type: :call_service, domain: :fan, service: :turn_on,
              service_data: { speed: speed }, target: { entity_id: entity_id })
  end

  def fan_off(entity_id, _speed = nil)
    send_data(type: :call_service, domain: :fan, service: :turn_off,
              target: { entity_id: entity_id })
  end

  def fan_set(entity_id, speed)
    speed.to_i.zero? ? fan_off(entity_id) : fan_on(entity_id, speed)
  end

  def switch_on(entity_id)
    send_data(type: :call_service, domain: :light, service: :turn_on,
              target: { entity_id: entity_id })
  end

  def switch_off(entity_id)
    send_data(type: :call_service, domain: :light, service: :turn_off,
              target: { entity_id: entity_id })
  end

  def dimmer_on(entity_id, level)
    send_data(type: :call_service, domain: :light, service: :turn_on,
              service_data: { brightness_pct: level }, target: { entity_id: entity_id })
  end

  def dimmer_off(entity_id)
    send_data(type: :call_service, domain: :light, service: :turn_off,
              target: { entity_id: entity_id })
  end

  def dimmer_set(entity_id, level)
    level.to_i.zero? ? dimmer_off(entity_id) : dimmer_on(entity_id, level)
  end

  def shade_set(entity_id, level)
    send_data(type: :call_service, domain: :cover, service: :set_cover_position,
              service_data: { position: level }, target: { entity_id: entity_id })
  end

  def lock_lock(entity_id)
    send_data(type: :call_service, domain: :lock, service: :lock,
              target: { entity_id: entity_id })
  end

  def unlock_lock(entity_id)
    send_data(type: :call_service, domain: :lock, service: :unlock,
              target: { entity_id: entity_id })
  end

  def button_press(entity_id)
    send_data(type: :call_service, domain: :button, service: :press,
              target: { entity_id: entity_id })
  end
end

class HassCore
  include HassMessageParsingMethods
  include HassRequests

  POSTFIX = "\n"
  STATE_FILE = ENV['STATE_FILE'] || '/data/savant_hass_proxy_state.json'
  HA_PING_INTERVAL = (ENV['HA_PING_INTERVAL'] || '30').to_i
  SAVANT_HELLO_INTERVAL = (ENV['SAVANT_HELLO_INTERVAL'] || '10').to_i
  RECONNECT_MIN = (ENV['HA_RECONNECT_MIN'] || '1').to_i
  RECONNECT_MAX = (ENV['HA_RECONNECT_MAX'] || '30').to_i
  WS_QUEUE_MAX = (ENV['WS_QUEUE_MAX'] || '200').to_i
  REPLAY_MAX = (ENV['SAVANT_REPLAY_MAX'] || '2000').to_i

  def initialize(hass_address, token, filter = ['all'])
    @address = hass_address
    @token = token
    @filter = filter

    @shutdown = false
    @ha_authed = false
    @id = 0

    @ws_queue = []
    @reconnect_delay = RECONNECT_MIN
    @ha_ping_timer_started = false

    @timers = []
    @em_mutex = Mutex.new
    @em_thread = nil

    # Savant client swapping
    @client_mutex = Mutex.new
    @client = nil
    @client_reader_thread = nil

    # Cache last values to replay on reconnect
    @state_cache = {} # key => value (already stringified)

    @persisted = load_state
    apply_persisted_defaults

    ensure_em_running
    connect_websocket
    start_savant_heartbeat
  end

  def shutdown!
    return if @shutdown
    @shutdown = true
    cancel_timers!
    safe_close_client
    begin; @hass_ws&.close; rescue; end
  end

  # ---------- Savant attach/detach ----------
  def attach_client(client)
    setup_tcp_keepalive(client)

    old = nil
    @client_mutex.synchronize do
      old = @client
      @client = client
    end
    safe_close_socket(old) if old

    send_to_savant('hello,proxy=ha_savant,proto=1')
    send_to_savant('ready,ha=ok') if @ha_authed

    # Replay cache so Savant has immediate state
    replay_cache

    # Start reader thread for this socket (one per attached client)
    start_client_reader_thread(client)
  end

  def detach_client
    old = nil
    @client_mutex.synchronize do
      old = @client
      @client = nil
    end
    safe_close_socket(old) if old
  end

  # ---------- Savant IO ----------
  def start_client_reader_thread(sock)
    thr = Thread.new do
      loop do
        break if @shutdown
        line = nil
        begin
          line = sock.gets
        rescue IOError, SystemCallError
          break
        end
        break unless line
        from_savant(line.chomp)
      end
      # if current client died, detach (but keep HA alive)
      @client_mutex.synchronize do
        detach_client if @client == sock
      end
    end

    @client_mutex.synchronize do
      # Best effort: don't keep old thread reference; it will exit when socket closes
      @client_reader_thread = thr
    end
  end

  def start_savant_heartbeat
    add_timer(
      EM.add_periodic_timer(SAVANT_HELLO_INTERVAL) do
        next if @shutdown
        send_to_savant('hello,proxy=ha_savant,proto=1')
      end
    )
  end

  def send_to_savant(*message)
    return if @shutdown
    sock = nil
    @client_mutex.synchronize { sock = @client }
    return unless sock && !sock.closed?

    payload = map_message(message).join
    sock.write(payload)

  rescue => _e
    # Detach dead socket; HA continues
    detach_client
  end

  def map_message(message)
    Array(message).map { |m| m ? [m.to_s.gsub(POSTFIX, ''), POSTFIX] : nil }.compact
  end

  # Cache every outgoing key===value
  def cache_outgoing(msg)
    # expect "key===value"
    if (i = msg.index('==='))
      k = msg[0...i]
      v = msg[(i+3)..-1]
      @state_cache[k] = v
    end
  end

  def replay_cache
    return if @shutdown
    sock = nil
    @client_mutex.synchronize { sock = @client }
    return unless sock && !sock.closed?

    count = 0
    @state_cache.each do |k, v|
      sock.write("#{k}===#{v}#{POSTFIX}")
      count += 1
      break if count >= REPLAY_MAX
    end
    p([:info, :replayed_cache, count])
  rescue
    detach_client
  end

  # Override update? path via send_to_savant -> cache as well
  def send_to_savant_with_cache(msg)
    cache_outgoing(msg)
    send_to_savant(msg)
  end

  # Monkey-patch point: update? uses send_to_savant; we redirect to cached version
  def send_to_savant(*message)
    return if @shutdown
    Array(message).each do |m|
      next unless m
      if m.include?('===')
        send_to_savant_with_cache(m)
      else
        sock = nil
        @client_mutex.synchronize { sock = @client }
        next unless sock && !sock.closed?
        sock.write("#{m}#{POSTFIX}")
      end
    end
  rescue
    detach_client
  end

  # ---------- HA WebSocket ----------
  def ensure_em_running
    return if EM.reactor_running?
    @em_mutex.synchronize do
      return if EM.reactor_running?
      @em_thread ||= Thread.new { EM.run }
    end
    50.times { break if EM.reactor_running?; sleep 0.05 }
  end

  def connect_websocket
    EM.schedule { start_ws }
  end

  def start_ws
    return if @shutdown
    @ha_authed = false
    @hass_ws = Faye::WebSocket::Client.new(@address)

    @hass_ws.on :open do
      p([:debug, :ws_connected])
      @reconnect_delay = RECONNECT_MIN
    end

    @hass_ws.on :message do |event|
      handle_message(event.data) unless @shutdown
    end

    @hass_ws.on :close do |event|
      p([:debug, :ws_disconnected, event.code, event.reason])
      @hass_ws = nil
      schedule_reconnect unless @shutdown
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
    add_timer(EM.add_timer(delay) { start_ws })
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
    add_timer(
      EM.add_periodic_timer(HA_PING_INTERVAL) do
        next if @shutdown
        send_json(type: 'ping')
      end
    )
  end

  def handle_message(data)
    message = JSON.parse(data) rescue nil
    return unless message
    return p([:error, [:request_failed, message]]) if message['success'] == false
    handle_hash(message)
  end

  def after_auth_ok
    p([:info, :ha_ready])
    start_ha_ping

    ents = persisted_entities
    subscribe_entities(ents) unless ents.empty?

    flush_ws_queue
    send_to_savant('ready,ha=ok') # if Savant attached, it becomes ready immediately
  end

  def handle_hash(message)
    case message['type']
    when 'auth_required' then send_auth
    when 'auth_ok'
      @ha_authed = true
      after_auth_ok
    when 'event'  then parse_event(message['event'])
    when 'result' then parse_result(message)
    when 'pong'   then p([:debug, :pong_received])
    end
  end

  def send_auth
    safe_ws_send({ type: 'auth', access_token: @token }.to_json)
  end

  def send_json(hash)
    # Add id to all non-auth messages
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

  # ---------- State persistence ----------
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
    if (@filter.nil? || @filter.empty? || @filter == ['all']) &&
       @persisted['filter'].is_a?(Array) && !@persisted['filter'].empty?
      @filter = @persisted['filter']
      p([:info, :filter_restored, @filter])
    end
  end

  def persisted_entities
    @persisted['entities'].is_a?(Array) ? @persisted['entities'] : []
  end

  def persist_filter(params)
    @persisted['filter'] = params
    save_state
  end

  def persist_entities(params)
    @persisted['entities'] = params
    save_state
  end

  # ---------- Savant commands ----------
  def hass_request?(cmd)
    HassRequests.instance_methods(false).include?(cmd.to_sym)
  end

  def from_savant(req)
    cmd, *params = req.split(',')
    case cmd
    when 'subscribe_events'
      send_json(type: 'subscribe_events')
    when 'subscribe_entity'
      entities = params.flatten.compact.reject(&:empty?)
      persist_entities(entities) unless entities.empty?
      subscribe_entities(entities) unless entities.empty?
    when 'state_filter'
      @filter = params
      persist_filter(@filter)
    else
      if hass_request?(cmd)
        send(cmd, *params)
      else
        p([:error, [:unknown_cmd, cmd, req]])
      end
    end
  end

  def subscribe_entities(entity_ids)
    send_json(type: 'subscribe_entities', entity_ids: entity_ids)
  end

  # ---------- Timers / sockets ----------
  def add_timer(t); @timers << t if t; t; end

  def cancel_timers!
    @timers.each { |t| t.cancel rescue nil }
    @timers.clear
  end

  def safe_close_socket(sock)
    sock&.close rescue nil
  end

  def safe_close_client
    sock = nil
    @client_mutex.synchronize do
      sock = @client
      @client = nil
    end
    safe_close_socket(sock)
  end

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
end

# ---------------- TCP Server ----------------
Thread.abort_on_exception = true

core = HassCore.new(WS_URL, WS_TOKEN, ['all'])

server = TCPServer.new(TCP_PORT)
server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1) rescue nil
p([:info, :server_started, TCP_PORT])

loop do
  client = server.accept
  p([:info, :client_connected, (client.peeraddr rescue :unknown_peer)])
  core.attach_client(client)
end
