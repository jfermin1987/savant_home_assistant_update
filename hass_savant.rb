#!/usr/bin/env ruby
# frozen_string_literal: true

# Savant <-> Home Assistant TCP proxy (multi-client)
# Optimized for production:
# - Multi-client: supports multiple Savant profiles simultaneously (lights, HVAC, locks, shades)
# - Single HA WebSocket (shared)
# - Aggregated HA subscriptions (subscribe_entities)
# - Thread-safe, monotonic HA request IDs (prevents id_reuse)
# - Robust HA reconnect + queue
# - Low-noise logging (info by default) with key lifecycle breadcrumbs
# - Cache priming via one-time get_states after HA auth_ok (so new clients can hydrate UI immediately)

require 'json'
require 'eventmachine'
require 'faye/websocket'
require 'securerandom'

# -------------------------
# Logging
# -------------------------

LOG_LEVELS = {
  'debug' => 0,
  'info'  => 1,
  'error' => 2
}.freeze

$stdout.sync = true

def log_level
  @log_level ||= LOG_LEVELS[(ENV['LOG_LEVEL'] || 'info').downcase] || 1
end

def log_debug(*args)
  return unless log_level <= 0
  p([:debug, *args])
end

def log_info(*args)
  return unless log_level <= 1
  p([:info, *args])
end

def log_error(*args)
  p([:error, *args])
end

# -------------------------
# HA WebSocket client
# -------------------------
class HaWs
  DEFAULT_WS = 'ws://supervisor/core/api/websocket'

  def initialize(token:, address: DEFAULT_WS)
    @token = token
    @address = address

    @ws = nil
    @ws_ready = false

    @next_id = 0
    @id_mutex = Mutex.new

    @send_queue = []
    @reconnect_attempt = 0
    @reconnect_timer = nil
    @ping_timer = nil

    @subscribed_entities = {} # entity_id => true

    @on_event = nil
    @on_ready = nil
    @on_get_states = nil

    @pending_get_states_id = nil
  end

  attr_reader :subscribed_entities

  def on_event(&blk) = (@on_event = blk)
  def on_ready(&blk) = (@on_ready = blk)
  def on_get_states(&blk) = (@on_get_states = blk)

  def start
    connect
  end

  def stop
    @ws_ready = false
    @ping_timer&.cancel
    @ping_timer = nil
    @reconnect_timer&.cancel
    @reconnect_timer = nil

    begin
      @ws&.close(1000, '')
    rescue StandardError
      # ignore
    end
    @ws = nil
  end

  def ready? = @ws_ready

  def ensure_subscribed(entity_ids)
    ids = Array(entity_ids).compact.map(&:strip).reject(&:empty?)
    return if ids.empty?

    new_ids = ids.reject { |e| @subscribed_entities[e] }
    return if new_ids.empty?

    new_ids.each { |e| @subscribed_entities[e] = true }
    log_info(:ha_subscribe_entities, new_ids.length)

    send_json(type: 'subscribe_entities', entity_ids: new_ids)
  end

  def call_service(domain:, service:, entity_id:, service_data: nil)
    payload = {
      type: 'call_service',
      domain: domain.to_s,
      service: service.to_s,
      target: { entity_id: entity_id.to_s }
    }
    payload[:service_data] = service_data if service_data && !service_data.empty?
    send_json(payload)
  end

  def request_get_states
    send_json({ type: 'get_states' }, track_result: :get_states)
  end

  private

  def next_id
    @id_mutex.synchronize do
      @next_id += 1
      @next_id
    end
  end

  def send_json(payload, track_result: nil)
    op = lambda do
      pl = payload.dup
      pl[:id] ||= next_id
      @pending_get_states_id = pl[:id] if track_result == :get_states

      json = JSON.generate(pl)
      @ws.send(json)
      log_debug(:ha_send, json)
    rescue StandardError => e
      log_error(:ws_send_error, e.class.name, e.message)
    end

    ptype = payload.is_a?(Hash) ? (payload[:type] || payload['type']) : nil

    # IMPORTANT: auth must bypass ws_ready gate or we deadlock.
    if (@ws_ready || ptype == 'auth') && @ws
      op.call
    else
      @send_queue << op
      log_debug(:ws_queued, @send_queue.length)
    end
  end

  def flush_queue
    return unless @ws_ready && @ws

    q = @send_queue
    @send_queue = []
    q.each(&:call)
    log_info(:ws_queue_flushed)
  end

  def connect
    log_info(:connecting_to, @address)

    @ws_ready = false
    @ws = Faye::WebSocket::Client.new(@address)

    @ws.on(:open) do |_|
      log_info(:ws_connected)
      @reconnect_attempt = 0
      @reconnect_timer&.cancel
      @reconnect_timer = nil
      schedule_ping
    end

    @ws.on(:message) do |event|
      handle_message(event.data)
    rescue StandardError => e
      log_error(:ws_message_error, e.class.name, e.message)
    end

    @ws.on(:close) do |event|
      log_info(:ws_disconnected, event.code, event.reason)
      @ws_ready = false
      @ws = nil
      @pending_get_states_id = nil
      schedule_reconnect
    end

    @ws.on(:error) do |event|
      msg = event.respond_to?(:message) ? event.message : event.to_s
      log_error(:ws_error, msg)
    end
  rescue StandardError => e
    log_error(:ws_connect_error, e.class.name, e.message)
    schedule_reconnect
  end

  def schedule_reconnect
    return if @reconnect_timer

    @reconnect_attempt += 1
    delay = [2**(@reconnect_attempt - 1), 30].min.to_f
    log_info(:ws_reconnect_scheduled, delay)
    @reconnect_timer = EM.add_timer(delay) do
      @reconnect_timer = nil
      connect
    end
  end

  def schedule_ping
    @ping_timer&.cancel
    @ping_timer = EM.add_periodic_timer(30) do
      @ws&.ping
    rescue StandardError
      # ignore
    end
  end

  def handle_message(data)
    msg = JSON.parse(data)

    case msg['type']
    when 'auth_required'
      log_debug(:ha_auth_required, msg['ha_version'])
      send_json(type: 'auth', access_token: @token)
    when 'auth_ok'
      @ws_ready = true
      log_info(:ha_ready)
      restore_subscriptions
      flush_queue
      request_get_states
      @on_ready&.call
    when 'event'
      @on_event&.call(msg)
    when 'pong'
      log_debug(:pong_received)
    when 'result'
      if msg['success']
        if @pending_get_states_id && msg['id'] == @pending_get_states_id
          @pending_get_states_id = nil
          @on_get_states&.call(msg['result'])
          log_info(:ha_states_primed)
        end
      else
        log_error(:request_failed, msg)
      end
    else
      log_debug(:ha_message, msg['type'])
    end
  end

  def restore_subscriptions
    ids = @subscribed_entities.keys
    log_info(:restoring_subscriptions, ids.length)
    return if ids.empty?

    ids.each_slice(200) do |chunk|
      send_json(type: 'subscribe_entities', entity_ids: chunk)
    end
  end
end

# -------------------------
# Savant client connection
# -------------------------
class SavantConn < EM::Connection
  attr_reader :client_key

  def initialize(proxy)
    super()
    @proxy = proxy
    @buf = +''
    @client_key = SecureRandom.hex(4) # 8 hex chars

    @filter = ['state']
    @subs = {}
    @subscribe_all = false
  end

  def post_init
    peer = begin
      Socket.unpack_sockaddr_in(get_peername).reverse
    rescue StandardError
      ['unknown', 0]
    end
    log_info(:client_connected, peer, @client_key)
    @proxy.register_client(self)
  end

  def unbind
    log_info(:client_disconnected, @client_key)
    @proxy.unregister_client(self)
  end

  def receive_data(data)
    @buf << data
    while (idx = @buf.index("\n"))
      line = @buf.slice!(0, idx + 1).strip
      next if line.empty?
      handle_line(line)
    end
  rescue StandardError => e
    log_error(:savant_receive_error, e.class.name, e.message)
  end

  def send_update(entity_id, key, value)
    msg = "#{entity_id}_#{key}===#{value}\n"
    send_data(msg)
  rescue StandardError => e
    log_error(:savant_send_error, e.class.name, e.message)
  end

  def subscribed_to?(entity_id)
    @subscribe_all || @subs[entity_id]
  end

  def filter
    @filter
  end

  private

  def handle_line(line)
    parts = line.split(',')
    if parts[0] =~ /^[0-9a-f]{8}$/i && parts.length >= 2
      cmd = parts[1]
      args = parts[2..]
    else
      cmd = parts[0]
      args = parts[1..]
    end

    log_debug(:from_savant, @client_key, cmd, args)

    case cmd
    when 'hello', 'heartbeat'
      # ignore
    when 'state_filter'
      new_filter = args.join(',').split(',').map { |s| s.strip }.reject(&:empty?)
      new_filter = ['state'] if new_filter.empty?
      if new_filter != @filter
        @filter = new_filter
        @proxy.save_filter(@client_key, @filter)
      end
    when 'subscribe_all_events'
      @subscribe_all = (args.first.to_s.strip.upcase == 'YES')
      log_info(:subscribe_all_events, @client_key, @subscribe_all)
    when 'subscribe_entity'
      ids = args.join(',').split(',').map(&:strip).reject(&:empty?)
      if ids.empty?
        log_info(:subscribe_entity_empty, @client_key)
      else
        ids.each { |e| @subs[e] = true }
        log_info(:subscribe_entity, @client_key, ids.length, ids[0, 6])
        @proxy.ensure_ha_subscribed(self, ids)
      end
    else
      @proxy.handle_action(cmd, args)
    end
  end
end

# -------------------------
# Main proxy
# -------------------------
class HassProxy
  def initialize(token:, address: HaWs::DEFAULT_WS)
    @clients = {}
    @entity_cache = {}

    @ha = HaWs.new(token: token, address: address)
    @ha.on_event { |msg| handle_ha_event(msg) }
    @ha.on_get_states { |list| prime_cache(list) }
  end

  def start
    @ha.start
  end

  def register_client(conn)
    @clients[conn.client_key] = conn
  end

  def unregister_client(conn)
    @clients.delete(conn.client_key)
  end

  def save_filter(client_key, filter)
    log_info(:filter_set, client_key, filter)
  end

  def ensure_ha_subscribed(client, entity_ids)
    @ha.ensure_subscribed(entity_ids)

    Array(entity_ids).each do |eid|
      packed = @entity_cache[eid]
      next unless packed
      forward_entity(eid, packed, only_client: client)
    end
  end

  def handle_action(cmd, args)
    case cmd
    when 'socket_on', 'switch_on'
      service_call('switch', 'turn_on', args[0])
    when 'socket_off', 'switch_off'
      service_call('switch', 'turn_off', args[0])
    when 'dimmer_on'
      service_call('light', 'turn_on', args[0])
    when 'dimmer_off'
      service_call('light', 'turn_off', args[0])
    when 'dimmer_set'
      entity = args[0]
      pct = (args[1] || '0').to_f
      service_call('light', 'turn_on', entity, { brightness_pct: pct })
    when 'shade_set'
      entity = args[0]
      pos = (args[1] || '0').to_i
      service_call('cover', 'set_cover_position', entity, { position: pos })
    when 'lock_lock'
      service_call('lock', 'lock', args[0])
    when 'unlock_lock'
      service_call('lock', 'unlock', args[0])
    when 'climate_set_hvac_mode'
      entity = args[0]
      mode = (args[1] || 'off').to_s
      service_call('climate', 'set_hvac_mode', entity, { hvac_mode: mode })
    when 'climate_set_single'
      entity = args[0]
      temp = (args[1] || '0').to_f
      service_call('climate', 'set_temperature', entity, { temperature: temp })
    when 'climate_set_low'
      entity = args[0]
      low = (args[1] || '0').to_f
      high = (args[2] || '0').to_f
      service_call('climate', 'set_temperature', entity, { target_temp_low: low, target_temp_high: high })
    when 'climate_set_high'
      entity = args[0]
      high = (args[1] || '0').to_f
      service_call('climate', 'set_temperature', entity, { temperature: high })
    else
      log_debug(:unhandled_action, cmd, args)
    end
  end

  private

  def service_call(domain, service, entity, service_data = nil)
    return if entity.to_s.strip.empty?

    log_info(:ha_service_call, domain, service, entity, service_data || {})
    @ha.call_service(domain: domain, service: service, entity_id: entity, service_data: service_data)
  end

  def prime_cache(states)
    return unless states.is_a?(Array)

    states.each do |st|
      eid = st['entity_id']
      next unless eid
      @entity_cache[eid] = { 's' => st['state'], 'a' => st['attributes'] || {} }
    end
  rescue StandardError => e
    log_error(:prime_cache_error, e.class.name, e.message)
  end

  def handle_ha_event(msg)
    ev = msg['event'] || {}
    data = ev['a'] || {}
    changes = ev['c'] || {}

    data.each do |entity_id, packed|
      @entity_cache[entity_id] = packed
      forward_entity(entity_id, packed)
    end

    changes.each do |entity_id, diff|
      next unless diff.is_a?(Hash) && diff['+'].is_a?(Hash)
      packed = diff['+']

      prev = @entity_cache[entity_id]
      if prev && prev['a'].is_a?(Hash)
        packed = packed.dup
        packed['a'] = (prev['a'] || {}).merge(packed['a'] || {})
      end

      @entity_cache[entity_id] = packed
      forward_entity(entity_id, packed)
    end
  rescue StandardError => e
    log_error(:ha_event_error, e.class.name, e.message)
  end

  def forward_entity(entity_id, packed, only_client: nil)
    state = packed['s']
    attrs = packed['a'] || {}

    targets = only_client ? [only_client] : @clients.values

    targets.each do |client|
      next unless client && client.subscribed_to?(entity_id)

      client.filter.each do |k|
        case k
        when 'state'
          client.send_update(entity_id, 'state', state) unless state.nil?
        when 'attributes'
          client.send_update(entity_id, 'attributes', JSON.generate(attrs))
        else
          v = attrs[k]
          client.send_update(entity_id, k, v) unless v.nil?
        end
      end

      if entity_id.start_with?('climate.')
        hvac_mode = attrs['hvac_mode']
        hvac_action = attrs['hvac_action']
        client.send_update(entity_id, 'hvac_mode', hvac_mode) if hvac_mode
        client.send_update(entity_id, 'hvac_action', hvac_action) if hvac_action
      end
    end
  end
end

# -------------------------
# Boot
# -------------------------

token = ENV['SUPERVISOR_TOKEN'] || ENV['HASS_TOKEN'] || ''
warn 'Missing SUPERVISOR_TOKEN/HASS_TOKEN env var' if token.to_s.strip.empty?

address = ENV['HASS_WS'] || HaWs::DEFAULT_WS
port = (ENV['SAVANT_TCP_PORT'] || '8080').to_i
bind = ENV['SAVANT_BIND'] || '0.0.0.0'

EM.run do
  proxy = HassProxy.new(token: token, address: address)
  proxy.start

  EM.start_server(bind, port, SavantConn, proxy)
  log_info(:server_started, port, { bind: bind, ha: address, log_level: (ENV['LOG_LEVEL'] || 'info') })
end
