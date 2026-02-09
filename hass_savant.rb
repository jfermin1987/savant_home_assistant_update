WS_TOKEN = ENV['SUPERVISOR_TOKEN']
WS_URL = "ws://supervisor/core/api/websocket"
TCP_PORT = 8080
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
    when 'call_service' then parse_service(new_data(js_data))
    else
      [:unknown, js_data['event_type']]
    end
  end

  def entities_changed(entities)
    entities.each do |entity, state|
      state = state['+'] if state.key?('+')
      p([:debug, ([:changed, entity, state])])
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
    when Hash then update_with_hash(eid, atr)
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
      when Hash then update_with_hash(key, e)
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
    p([:debug, ([:jsdata, js_data])])
    res = js_data['result']
    return unless res

    p([:debug, ([:parsing, res.length])])
    return parse_state(res) unless res.is_a?(Array)

    res.each do |e|
      p([:debug, ([:parsing, e.length, e.keys])])
      parse_state(e)
    end
  end
end

module HassRequests
  def fan_on(entity_id, speed)
    send_data(
      type: :call_service, domain: :fan, service: :turn_on,
      service_data: { speed: speed },
      target: { entity_id: entity_id }
    )
  end

  def fan_off(entity_id, _speed)
    send_data(
      type: :call_service, domain: :fan, service: :turn_off,
      target: { entity_id: entity_id }
    )
  end

  def fan_set(entity_id, speed)
    speed.to_i.zero? ? fan_off(entity_id) : fan_on(entity_id, speed)
  end

  def switch_on(entity_id)
    send_data(
      type: :call_service, domain: :light, service: :turn_on,
      target: { entity_id: entity_id }
    )
  end

  def switch_off(entity_id)
    send_data(
      type: :call_service, domain: :light, service: :turn_off,
      target: { entity_id: entity_id }
    )
  end

  def dimmer_on(entity_id, level)
    send_data(
      type: :call_service, domain: :light, service: :turn_on,
      service_data: { brightness_pct: level },
      target: { entity_id: entity_id }
    )
  end

  def dimmer_off(entity_id)
    send_data(
      type: :call_service, domain: :light, service: :turn_off,
      target: { entity_id: entity_id }
    )
  end

  def dimmer_set(entity_id, level)
    level.to_i.zero? ? dimmer_off(entity_id) : dimmer_on(entity_id, level)
  end

  def shade_set(entity_id, level)
    send_data(
      type: :call_service, domain: :cover, service: :set_cover_position,
      service_data: { position: level },
      target: { entity_id: entity_id }
    )
  end

  def lock_lock(entity_id)
    send_data(
      type: :call_service, domain: :lock, service: :lock,
      target: { entity_id: entity_id }
    )
  end

  def unlock_lock(entity_id)
    send_data(
      type: :call_service, domain: :lock, service: :unlock,
      target: { entity_id: entity_id }
    )
  end

  def open_garage_door(entity_id)
    send_data(
      type: :call_service, domain: :cover, service: :open_cover,
      target: { entity_id: entity_id }
    )
  end

  def button_press(entity_id)
    send_data(
      type: :call_service, domain: :button, service: :press,
      target: { entity_id: entity_id }
    )
  end

  def close_garage_door(entity_id)
    send_data(
      type: :call_service, domain: :cover, service: :close_cover,
      target: { entity_id: entity_id }
    )
  end

  def toggle_garage_door(entity_id)
    send_data(
      type: :call_service, domain: :cover, service: :toggle,
      target: { entity_id: entity_id }
    )
  end

  def socket_on(entity_id)
    send_data(
      type: :call_service, domain: :switch, service: :turn_on,
      target: { entity_id: entity_id }
    )
  end

  def socket_off(entity_id)
    send_data(
      type: :call_service, domain: :switch, service: :turn_off,
      target: { entity_id: entity_id }
    )
  end

  def climate_set_hvac_mode(entity_id, mode)
    send_data(
      type: :call_service, domain: :climate, service: :set_hvac_mode,
      service_data: { hvac_mode: mode },
      target: { entity_id: entity_id }
    )
  end
  
  def climate_set_single(entity_id, level)
    send_data(
      type: :call_service, domain: :climate, service: :set_temperature,
      service_data: { temperature: level },
      target: { entity_id: entity_id }
    )
  end

  def climate_set_low(entity_id, low_level)
    send_data(
      type: :call_service, domain: :climate, service: :set_temperature,
      service_data: { target_temp_low: low_level },
      target: { entity_id: entity_id }
    )
  end

  def climate_set_high(entity_id, high_level)
    send_data(
      type: :call_service, domain: :climate, service: :set_temperature,
      service_data: { target_temp_high: high_level },
      target: { entity_id: entity_id }
    )
  end
end

def remote_on(entity_id)
  send_data(
    type: :call_service, domain: :remote, service: :turn_on,
    target: { entity_id: entity_id }
  )
end

def remote_off(entity_id)
  send_data(
    type: :call_service, domain: :remote, service: :turn_off,
    target: { entity_id: entity_id }
  )
end

def remote_send_command(entity_id)
  send_data(
    type: :call_service, domain: :remote, service: :send_command,
    service_data: { command: command },
    target: { entity_id: entity_id }
  )
end

def media_player_on(entity_id)
  send_data(
    type: :call_service, domain: :media_player, service: :turn_on,
    target: { entity_id: entity_id }
  )
end

def media_player_off(entity_id)
  send_data(
    type: :call_service, domain: :media_player, service: :turn_off,
    target: { entity_id: entity_id }
  )
end

def mediaplayer_send_command(entity_id)
  send_data(
    type: :call_service, domain: :remote, service: :send_command,
    service_data: { command: command },
    target: { entity_id: entity_id }
  )
end

class Hass
  include HassMessageParsingMethods
  include HassRequests

  POSTFIX = "
"
  STATE_FILE = ENV['STATE_FILE'] || '/data/savant_hass_proxy_state.json'
  HA_PING_INTERVAL = (ENV['HA_PING_INTERVAL'] || '30').to_i
  SAVANT_HELLO_INTERVAL = (ENV['SAVANT_HELLO_INTERVAL'] || '10').to_i
  RECONNECT_MIN = (ENV['HA_RECONNECT_MIN'] || '1').to_i
  RECONNECT_MAX = (ENV['HA_RECONNECT_MAX'] || '30').to_i
  WS_QUEUE_MAX = (ENV['WS_QUEUE_MAX'] || '200').to_i

  def initialize(hass_address, token, client, filter = ['all'])
    p([:debug, :connecting_to, hass_address])
    @address = hass_address
    @token = token
    @filter = filter
    @client = client

    @shutdown = false
    @ha_authed = false
    @id = 0
    @ws_queue = []
    @reconnect_delay = RECONNECT_MIN

    @em_mutex = Mutex.new
    @em_thread = nil

    @persisted = load_state
    apply_persisted_defaults

    setup_tcp_keepalive(@client)
    ensure_em_running
    start_savant_io
    connect_websocket
  end

  def subscribe_entities(*entity_id)
    return if entity_id.empty?
    send_json(type: 'subscribe_entities', entity_ids: entity_id.flatten)
  end

  def send_data(**data)
    p([:debug, data])
    send_json(data)
  end

  private

  # ---------------------------
  # Persistence (survive HA/Savant reboots)
  # ---------------------------
  def load_state
    JSON.parse(File.read(STATE_FILE))
  rescue
    { 'filter' => nil, 'entities' => [] }
  end

  def save_state
    dir = File.dirname(STATE_FILE)
    Dir.mkdir(dir) unless Dir.exist?(dir)
    File.write(STATE_FILE, @persisted.to_json)
  rescue => e
    p([:error, :state_save_failed, e.message])
  end

  def apply_persisted_defaults
    # If Savant hasn't set a filter yet, use last known one
    if (@filter.nil? || @filter.empty? || @filter == ['all']) && @persisted['filter'].is_a?(Array) && !@persisted['filter'].empty?
      @filter = @persisted['filter']
      p([:info, :filter_restored, @filter])
    end
  end

  def persisted_entities
    arr = @persisted['entities']
    arr.is_a?(Array) ? arr : []
  end

  def persist_filter(params)
    @persisted['filter'] = params
    save_state
  end

  def persist_entities(params)
    @persisted['entities'] = params
    save_state
  end

  # ---------------------------
  # Savant IO + Heartbeat
  # ---------------------------
  def start_savant_io
    @last_savant_rx = Time.now
    send_to_savant('hello,proxy=ha_savant,proto=1')
    start_savant_heartbeat
    listen_to_savant
  end

  def listen_to_savant
    Thread.new do
      p([:starting_listening_to_savant])
      loop do
        request = nil
        begin
          request = @client.gets
        rescue IOError, SystemCallError => e
          p([:error, :savant_read_error, e.class.to_s, e.message])
          shutdown!
          break
        end

        request = request&.chomp
        if request
          @last_savant_rx = Time.now
          p([:debug, :from_savant, request])
          from_savant(request)
        else
          p([:debug, :savant_disconnected])
          shutdown!
          break
        end
      end
    end
  end

  def start_savant_heartbeat
    em_add_periodic_timer(SAVANT_HELLO_INTERVAL) do
      next if @shutdown
      # If Savant stays connected but doesn't send its config after reboot,
      # this 'hello' nudges it (and helps detect half-open sockets).
      send_to_savant('hello,proxy=ha_savant,proto=1')
    end
  end

  def send_to_savant(*message)
    return unless message
    @client.puts(map_message(message).join)
  rescue => e
    p([:error, :to_savant_failed, e.message])
  end

  # ---------------------------
  # Home Assistant WebSocket (auto reconnect + queue)
  # ---------------------------
  
  def em_add_timer(seconds, &blk)
    ensure_em_running
    EM.add_timer(seconds, &blk)
  end

  def em_add_periodic_timer(seconds, &blk)
    ensure_em_running
    EM.add_periodic_timer(seconds, &blk)
  end

  def em_schedule(&blk)
    ensure_em_running
    EM.schedule(&blk)
  end

def ensure_em_running
    return if EM.reactor_running?

    @em_mutex.synchronize do
      return if EM.reactor_running?
      @em_thread ||= Thread.new do
        EM.run
      end
    end

    # Spin-wait briefly for reactor
    50.times do
      break if EM.reactor_running?
      sleep 0.05
    end
  end

  def connect_websocket
    EM.schedule { start_ws }
  end

  def start_ws
    return if @shutdown
    @ha_authed = false
    ws_url = @address
    @hass_ws = Faye::WebSocket::Client.new(ws_url)

    @hass_ws.on :open do |_event|
      p([:debug, :ws_connected])
      @reconnect_delay = RECONNECT_MIN

    @em_mutex = Mutex.new
    @em_thread = nil
    end

    @hass_ws.on :message do |event|
      handle_message(event.data)
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
    em_add_timer(delay) { start_ws }
  end

  def can_send_ws?
    @hass_ws && @hass_ws.ready_state == Faye::WebSocket::API::OPEN
  rescue
    false
  end

  def enqueue_ws(json)
    @ws_queue << json
    @ws_queue.shift while @ws_queue.length > WS_QUEUE_MAX
    p([:debug, :ws_queued, @ws_queue.length])
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

  # ---------------------------
  # Protocol handling
  # ---------------------------
  def hass_request?(cmd)
    cmd = cmd.to_sym
    HassRequests.instance_methods(false).include?(cmd.to_sym)
  end

  def from_savant(req)
    cmd, *params = req.split(',')
    if cmd == 'pong'
      p([:debug, :savant_pong])
    elsif cmd == 'subscribe_events'
      send_json(type: 'subscribe_events')
    elsif cmd == 'subscribe_entity'
      entities = params.flatten.compact.reject(&:empty?)
      persist_entities(entities) unless entities.empty?
      subscribe_entities(entities)
    elsif cmd == 'state_filter'
      @filter = params
      persist_filter(@filter)
    elsif hass_request?(cmd)
      send(cmd, *params)
    else
      p([:error, [:unknown_cmd, cmd, req]])
    end
  end

  def handle_message(data)
    message = JSON.parse(data) rescue nil
    return unless message
    return p([:error, [:request_failed, message]]) if message['success'] == false

    p([:debug, [:handling, message]])
    handle_hash(message)
  end

  def after_auth_ok
    p([:info, :ha_ready])
    start_ha_ping

    # If Savant hasn't pushed subscribe_entity yet after a reboot,
    # restore the last known set so state starts flowing immediately.
    ents = persisted_entities
    if !ents.empty?
      p([:info, :restoring_subscriptions, ents.length])
      subscribe_entities(ents)
    end

    flush_ws_queue
    send_to_savant('ready,ha=ok')
  end

  def handle_hash(message)
    case message['type']
    when 'auth_required' then send_auth
    when 'auth_ok'
      @ha_authed = true
      after_auth_ok
    when 'event' then parse_event(message['event'])
    when 'result' then parse_result(message)
    when 'pong' then p([:debug, :pong_received])
    end
  end

  def send_auth
    auth_message = { type: 'auth', access_token: @token }.to_json
    p([:debug, [:sending_auth]])
    safe_ws_send(auth_message)
  end

  def send_json(hash)
    @id += 1
    hash['id'] = @id
    json = hash.to_json
    p([:debug, [:send, json]])

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

  # ---------------------------
  # Socket keepalive (Linux)
  # ---------------------------
  def setup_tcp_keepalive(sock)
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
    if Socket.const_defined?(:IPPROTO_TCP)
      # Best-effort: these constants may not exist on all Ruby builds/platforms.
      sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPIDLE, 30) if Socket.const_defined?(:TCP_KEEPIDLE)
      sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPINTVL, 10) if Socket.const_defined?(:TCP_KEEPINTVL)
      sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPCNT, 3) if Socket.const_defined?(:TCP_KEEPCNT)
    end
  rescue => e
    p([:debug, :keepalive_not_set, e.message])
  end

    def shutdown?
    @shutdown
  end

def shutdown!
    return if @shutdown
    @shutdown = true
    begin
      @hass_ws&.close
    rescue
    end
    begin
      @client&.close
    rescue
    end
  end

  # ---------------------------
  # Existing helpers (unchanged)
  # ---------------------------
  def map_message(message)
    Array(message).map do |m|
      next unless m
      [m.to_s.gsub(POSTFIX, ''), POSTFIX]
    end
  end
end

# TCP Server: single-client oriented (close prior client on new connect) + restart-safe
Thread.abort_on_exception = true

def start_tcp_server(hass_address, token, port = 8080)
  server = TCPServer.new(port)
  p([:info, :server_started, port])

  current = nil

  loop do
    client = server.accept
    p([:info, :client_connected, client.peeraddr])

    # If a prior Savant connection exists, close it (avoid half-open multi-clients)
    begin
      current&.close
    rescue
    end

    Thread.new do
      begin
        current = client
        hass_instance = Hass.new(hass_address, token, client)
        p([:info, :hass_instance_created])
        sleep 0.5 until hass_instance.shutdown?
      rescue => e
        p([:error, :client_error, e.message])
        begin
          client.close
        rescue StandardError
        end
      end
    end
  end
end

start_tcp_server(WS_URL, WS_TOKEN)
