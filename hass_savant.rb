#!/usr/bin/env ruby
# frozen_string_literal: true

# Savant <-> Home Assistant TCP proxy (multi-profile)
# Goals:
# - Multi-client (multiple Savant profiles at once)
# - Single shared HA WebSocket
# - Per-client subscriptions/filters (profiles don't stomp each other)
# - Monotonic HA request IDs (fixes id_reuse)
# - Robust HA reconnect with backoff + queue
# - Quiet logs by default + de-dup spammy lines
# - Avoid huge get_states dumps (use update_entity per subscribed entity)

require 'json'
require 'eventmachine'
require 'faye/websocket'
require 'securerandom'
require 'socket'

# -------------------------
# Logging (levels + de-dup)
# -------------------------
class Logger
  LEVELS = {
    'debug' => 0,
    'info'  => 1,
    'warn'  => 2,
    'error' => 3
  }.freeze

  def initialize(level: ENV.fetch('LOG_LEVEL', 'info'))
    @level = LEVELS.fetch(level.to_s.downcase, 1)
    @last = {}
    $stdout.sync = true
  end

  def debug(*args) = log_at('debug', *args)
  def info(*args)  = log_at('info', *args)
  def warn(*args)  = log_at('warn', *args)
  def error(*args) = log_at('error', *args)

  # De-dup repeated logs within a time window.
  def dedup(key, window_s: 2)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    last = @last[key]
    return false if last && (now - last) < window_s

    @last[key] = now
    true
  end

  private

  def log_at(level, *args)
    return if LEVELS[level] < @level

    p([level.to_sym, *args])
  end
end

LOG = Logger.new

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
  end

  attr_reader :subscribed_entities

  def on_event(&blk) = (@on_event = blk)
  def on_ready(&blk) = (@on_ready = blk)

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
    ids = Array(entity_ids).compact.map { |s| s.to_s.strip }.reject(&:empty?)
    return if ids.empty?

    new_ids = ids.reject { |e| @subscribed_entities[e] }
    return if new_ids.empty?

    new_ids.each { |e| @subscribed_entities[e] = true }

    # HA supports incremental subscribe_entities calls.
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

  # Useful for forcing an update without pulling all states.
  def update_entity(entity_id)
    call_service(domain: 'homeassistant', service: 'update_entity', entity_id: entity_id)
  end

  private

  def next_id
    @id_mutex.synchronize do
      @next_id += 1
      @next_id
    end
  end

  def send_json(payload)
    op = lambda do
      pl = payload.dup
      pl[:id] ||= next_id
      json = JSON.generate(pl)
      @ws.send(json)
      LOG.debug(:send, json)
    rescue StandardError => e
      LOG.error(:ws_send_error, e.class.name, e.message)
    end

    ptype = payload.is_a?(Hash) ? (payload[:type] || payload['type']) : nil

    # Allow auth to be sent before ws_ready (avoid deadlock).
    if (@ws_ready || ptype == 'auth') && @ws
      op.call
    else
      @send_queue << op
      LOG.debug(:ws_queued, @send_queue.length)
    end
  end

  def flush_queue
    return unless @ws_ready && @ws

    q = @send_queue
    @send_queue = []
    q.each(&:call)
    LOG.info(:ws_queue_flushed)
  end

  def connect
    LOG.info(:connecting_to, @address)

    @ws_ready = false
    @ws = Faye::WebSocket::Client.new(@address)

    @ws.on(:open) do |_|
      LOG.info(:ws_connected)
      @reconnect_attempt = 0
      @reconnect_timer&.cancel
      @reconnect_timer = nil
      schedule_ping
    end

    @ws.on(:message) do |event|
      handle_message(event.data)
    rescue StandardError => e
      LOG.error(:ws_message_error, e.class.name, e.message)
    end

    @ws.on(:close) do |event|
      LOG.warn(:ws_disconnected, event.code, event.reason.to_s)
      @ws_ready = false
      @ws = nil
      schedule_reconnect
    end

    @ws.on(:error) do |event|
      msg = event.respond_to?(:message) ? event.message : event.to_s
      LOG.error(:ws_error, msg)
      # close handler will schedule reconnect
    end
  rescue StandardError => e
    LOG.error(:ws_connect_error, e.class.name, e.message)
    schedule_reconnect
  end

  def schedule_reconnect
    return if @reconnect_timer

    @reconnect_attempt += 1
    delay = [2**(@reconnect_attempt - 1), 30].min.to_f
    LOG.info(:ws_reconnect_scheduled, delay)
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
    LOG.debug(:handling, msg)

    case msg['type']
    when 'auth_required'
      send_json(type: 'auth', access_token: @token)
    when 'auth_ok'
      @ws_ready = true
      LOG.info(:ha_ready)
      restore_subscriptions
      flush_queue
      @on_ready&.call
    when 'event'
      @on_event&.call(msg)
    when 'pong'
      LOG.debug(:pong_received)
    when 'result'
      LOG.error(:request_failed, msg) unless msg['success']
    end
  end

  def restore_subscriptions
    ids = @subscribed_entities.keys
    LOG.info(:restoring_subscriptions, ids.length)
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
    @buf = +' '
    @buf.clear

    # NOTE: Savant may send its own 8-hex token prefix per line.
    # We keep a stable per-connection key.
    @client_key = SecureRandom.hex(4)

    @filter = ['state']
    @subs = {}
    @subscribe_all = false

    @last_filter_sig = nil
  end

  def post_init
    peer = begin
      Socket.unpack_sockaddr_in(get_peername).reverse
    rescue StandardError
      ['unknown', 0]
    end
    LOG.info(:client_connected, peer, @client_key)
    @proxy.register_client(self)
  end

  def unbind
    LOG.info(:client_disconnected, @client_key)
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
    LOG.error(:savant_receive_error, e.class.name, e.message)
  end

  def send_update(entity_id, key, value)
    # Match RPM xml expectations: <entity>_<key>===<value>\n
    send_data("#{entity_id}_#{key}===#{value}\n")
  rescue StandardError => e
    LOG.error(:savant_send_error, e.class.name, e.message)
  end

  def subscribed_to?(entity_id)
    @subscribe_all || @subs[entity_id]
  end

  def filter
    @filter
  end

  def subscriptions
    @subs.keys
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

    # Debug only; avoid massive logs by default
    LOG.debug(:from_savant, @client_key, line)

    case cmd
    when 'hello', 'heartbeat'
      # ignore
    when 'state_filter'
      filt = args.join(',').split(',').map { |s| s.strip }.reject(&:empty?)
      filt = ['state'] if filt.empty?

      sig = filt.join('|')
      # Savant profiles sometimes spam state_filter repeatedly; de-dup.
      unless sig == @last_filter_sig
        @last_filter_sig = sig
        @filter = filt
        @proxy.save_filter(@client_key, @filter)
      end
    when 'subscribe_all_events'
      @subscribe_all = (args.first.to_s.strip.upcase == 'YES')
    when 'subscribe_entity'
      ids = args.join(',').split(',').map { |s| s.strip }.reject(&:empty?)
      return if ids.empty? # IMPORTANT: Savant may send "subscribe_entity," (empty)

      ids.each { |e| @subs[e] = true }
      @proxy.ensure_ha_subscribed(ids)
      @proxy.force_update_entities(ids)
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
    @last_filter_by_client = {}

    @ha = HaWs.new(token: token, address: address)
    @ha.on_event { |msg| handle_ha_event(msg) }

    # Track last sent values per client/entity/key to prevent flooding Savant.
    @last_sent = Hash.new { |h, k| h[k] = {} } # client_key => {"entity|key" => value}
  end

  def start
    @ha.start
  end

  def register_client(conn)
    @clients[conn.client_key] = conn
  end

  def unregister_client(conn)
    @clients.delete(conn.client_key)
    @last_sent.delete(conn.client_key)
  end

  def save_filter(client_key, filter)
    @last_filter_by_client[client_key] = filter
    LOG.info(:filter_set, client_key, filter)
  end

  def ensure_ha_subscribed(entity_ids)
    @ha.ensure_subscribed(entity_ids)
  end

  # Prefer update_entity rather than get_states.
  def force_update_entities(entity_ids)
    Array(entity_ids).each do |eid|
      @ha.update_entity(eid)
    end
  rescue StandardError
    # ignore
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
      LOG.debug(:unhandled_action, cmd, args)
    end
  end

  private

  def service_call(domain, service, entity, service_data = nil)
    return if entity.to_s.strip.empty?

    # Keep info-level, but de-dup rapid repeats for same command/entity.
    dedup_key = "svc|#{domain}|#{service}|#{entity}|#{service_data.inspect}"
    LOG.info(:ha_service_call, domain, service, entity, (service_data || {})) if LOG.dedup(dedup_key, window_s: 0.25)

    @ha.call_service(domain: domain, service: service, entity_id: entity, service_data: service_data)
  end

  def handle_ha_event(msg)
    ev = msg['event'] || {}

    data = ev['a'] || {}
    changes = ev['c'] || {}

    data.each { |entity_id, packed| forward_entity(entity_id, packed) }

    changes.each do |entity_id, diff|
      next unless diff.is_a?(Hash) && diff['+'].is_a?(Hash)

      forward_entity(entity_id, diff['+'])
    end
  rescue StandardError => e
    LOG.error(:ha_event_error, e.class.name, e.message)
  end

  def forward_entity(entity_id, packed)
    state = packed['s']
    attrs = packed['a'] || {}

    @clients.each_value do |client|
      next unless client.subscribed_to?(entity_id)

      client.filter.each do |k|
        key = k.to_s
        val = case key
              when 'state'
                state
              when 'attributes'
                JSON.generate(attrs)
              else
                attrs[key]
              end

        next if val.nil?

        cache_key = "#{entity_id}|#{key}"
        last = @last_sent[client.client_key][cache_key]
        next if last == val

        @last_sent[client.client_key][cache_key] = val
        client.send_update(entity_id, key, val)
      end

      # Extra HVAC signals that some Savant UI bindings expect.
      if entity_id.start_with?('climate.')
        hvac_mode = attrs['hvac_mode']
        hvac_action = attrs['hvac_action']

        if hvac_mode
          cache_key = "#{entity_id}|hvac_mode"
          last = @last_sent[client.client_key][cache_key]
          if last != hvac_mode
            @last_sent[client.client_key][cache_key] = hvac_mode
            client.send_update(entity_id, 'hvac_mode', hvac_mode)
          end
        end

        if hvac_action
          cache_key = "#{entity_id}|hvac_action"
          last = @last_sent[client.client_key][cache_key]
          if last != hvac_action
            @last_sent[client.client_key][cache_key] = hvac_action
            client.send_update(entity_id, 'hvac_action', hvac_action)
          end
        end
      end
    end
  end
end

# -------------------------
# Boot
# -------------------------

token = ENV['SUPERVISOR_TOKEN'] || ENV['HASS_TOKEN'] || ''
warn('Missing SUPERVISOR_TOKEN/HASS_TOKEN env var') if token.to_s.strip.empty?

address = ENV['HASS_WS'] || HaWs::DEFAULT_WS
port = (ENV['SAVANT_TCP_PORT'] || '8080').to_i
bind = ENV['SAVANT_BIND'] || '0.0.0.0'

EM.run do
  proxy = HassProxy.new(token: token, address: address)
  proxy.start

  EM.start_server(bind, port, SavantConn, proxy)
  LOG.info(:server_started, port, { bind: bind, ha: address, log_level: ENV.fetch('LOG_LEVEL', 'info') })
end
