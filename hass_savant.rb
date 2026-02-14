#!/usr/bin/env ruby
# frozen_string_literal: true

# Savant <-> Home Assistant TCP proxy
# - Multi-client: supports multiple Savant profiles connecting simultaneously (lights, HVAC, locks, shades)
# - Single HA WebSocket: shared connection, subscriptions aggregated
# - Per-client filters/subscriptions so profiles don't stomp each other
# - Monotonic, thread-safe HA request IDs (fixes id_reuse)
# - Robust HA reconnect with exponential backoff and queue

require 'json'
require 'eventmachine'
require 'faye/websocket'
require 'uri'
require 'securerandom'

# -------------------------
# Logging helpers
# -------------------------

def log(*args)
  $stdout.sync = true
  p(args)
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
    ids = Array(entity_ids).compact.map(&:strip).reject(&:empty?)
    return if ids.empty?

    # only subscribe to entities we haven't subscribed to yet (global set)
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

  private

  def next_id
    @id_mutex.synchronize do
      @next_id += 1
      @next_id
    end
  end

  def send_json(payload)
    # Assign id at send-time (NOT at enqueue-time) to avoid id reuse/out-of-order
    op = lambda do
      payload = payload.dup
      payload[:id] ||= next_id
      json = JSON.generate(payload)
      @ws.send(json)
      log(:debug, [:send, json])
    rescue StandardError => e
      log(:error, :ws_send_error, e.class.name, e.message)
    end

    # NOTE: payload keys are usually symbols in our codepaths (type: 'auth'),
    # but some call sites may use string keys. Treat both.
    ptype = payload.is_a?(Hash) ? (payload[:type] || payload['type']) : nil

    # Allow auth to be sent before ws_ready (otherwise we deadlock and HA closes).
    if (@ws_ready || ptype == 'auth') && @ws
      op.call
    else
      @send_queue << op
      log(:debug, :ws_queued, @send_queue.length)
    end
  end

  def flush_queue
    return unless @ws_ready && @ws

    q = @send_queue
    @send_queue = []
    q.each(&:call)
    log(:info, :ws_queue_flushed)
  end

  def connect
    log(:debug, :connecting_to, @address)

    @ws_ready = false
    @ws = Faye::WebSocket::Client.new(@address)

    @ws.on(:open) do |_|
      log(:debug, :ws_connected)
      @reconnect_attempt = 0
      @reconnect_timer&.cancel
      @reconnect_timer = nil
      schedule_ping
    end

    @ws.on(:message) do |event|
      begin
        handle_message(event.data)
      rescue StandardError => e
        log(:error, :ws_message_error, e.class.name, e.message)
      end
    end

    @ws.on(:close) do |event|
      code = event.code
      reason = event.reason
      log(:debug, :ws_disconnected, code, reason)
      @ws_ready = false
      @ws = nil
      schedule_reconnect
    end

    @ws.on(:error) do |event|
      # faye-websocket puts string in event.message sometimes
      msg = event.respond_to?(:message) ? event.message : event.to_s
      log(:error, :ws_error, msg)
      # Let :close handler do reconnect
    end
  rescue StandardError => e
    log(:error, :ws_connect_error, e.class.name, e.message)
    schedule_reconnect
  end

  def schedule_reconnect
    return if @reconnect_timer

    @reconnect_attempt += 1
    # exp backoff: 1,2,4,8,16,30...
    delay = [2**(@reconnect_attempt - 1), 30].min.to_f
    log(:info, :ws_reconnect_scheduled, delay)
    @reconnect_timer = EM.add_timer(delay) do
      @reconnect_timer = nil
      connect
    end
  end

  def schedule_ping
    @ping_timer&.cancel
    @ping_timer = EM.add_periodic_timer(30) do
      begin
        @ws&.ping
      rescue StandardError
        # ignore
      end
    end
  end

  def handle_message(data)
    msg = JSON.parse(data)
    log(:debug, [:handling, msg])

    case msg['type']
    when 'auth_required'
      send_json(type: 'auth', access_token: @token)
    when 'auth_ok'
      @ws_ready = true
      log(:info, :ha_ready)
      # On reconnect, resubscribe everything we knew about
      restore_subscriptions
      flush_queue
      @on_ready&.call
    when 'event'
      @on_event&.call(msg)
    when 'pong'
      log(:debug, :pong_received)
    when 'result'
      unless msg['success']
        log(:error, :request_failed, msg)
      end
    end
  end

  def restore_subscriptions
    ids = @subscribed_entities.keys
    log(:info, :restoring_subscriptions, ids.length)
    return if ids.empty?

    # Re-subscribe in chunks to keep payload small
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
    log(:info, :client_connected, Socket.unpack_sockaddr_in(get_peername).reverse, @client_key)
    @proxy.register_client(self)
  end

  def unbind
    log(:info, :client_disconnected, @client_key)
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
    log(:error, :savant_receive_error, e.class.name, e.message)
  end

  def send_update(entity_id, key, value)
    # Match RPM xml expectations: <entity>_<key>===<value>\n
    msg = "#{entity_id}_#{key}===#{value}\n"
    send_data(msg)
  rescue StandardError => e
    log(:error, :savant_send_error, e.class.name, e.message)
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
    # Support optional prefix client_id used by some builds:
    #   <8hex>,command,...
    parts = line.split(',')
    if parts[0] =~ /^[0-9a-f]{8}$/i && parts.length >= 2
      # ignore provided token; we use per-connection key
      cmd = parts[1]
      args = parts[2..]
    else
      cmd = parts[0]
      args = parts[1..]
    end

    log(:debug, :from_savant, @client_key, line)

    case cmd
    when 'hello'
      # ignore
    when 'heartbeat'
      # ignore
    when 'state_filter'
      @filter = args.join(',').split(',').map { |s| s.strip }.reject(&:empty?)
      @filter = ['state'] if @filter.empty?
      @proxy.save_filter(@client_key, @filter)
    when 'subscribe_all_events'
      @subscribe_all = (args.first.to_s.strip.upcase == 'YES')
    when 'subscribe_entity'
      ids = args.join(',').split(',').map(&:strip).reject(&:empty?)
      ids.each { |e| @subs[e] = true }
      @proxy.ensure_ha_subscribed(ids)
    else
      # Actions
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
  end

  def start
    @ha.start
  end

  def register_client(conn)
    @clients[conn.client_key] = conn
    # restore previous filter for this key if any (rare; keys change per connection)
    if (f = @last_filter_by_client[conn.client_key])
      # no direct setter; client will send its state_filter anyway
    end
  end

  def unregister_client(conn)
    @clients.delete(conn.client_key)
    # IMPORTANT: do NOT shutdown HA WS on client disconnect (multi-profile stability)
  end

  def save_filter(client_key, filter)
    @last_filter_by_client[client_key] = filter
    log(:info, :filter_set, client_key, filter)
  end

  def ensure_ha_subscribed(entity_ids)
    @ha.ensure_subscribed(entity_ids)
    # After subscribe, ask HA for an immediate state dump so UI updates even if
    # the entity doesn't change for a while.
    request_state_refresh(entity_ids)
  end

  def handle_action(cmd, args)
    # cmd examples:
    # - socket_on,<entity>
    # - socket_off,<entity>
    # - lock_lock,<entity>
    # - unlock_lock,<entity>
    # - shade_set,<entity>,<pos>
    # - climate_set_hvac_mode,<entity>,cool
    # - climate_set_single,<entity>,24

    case cmd
    when 'socket_on'
      entity = args[0]
      service_call('switch', 'turn_on', entity)
    when 'socket_off'
      entity = args[0]
      service_call('switch', 'turn_off', entity)
    when 'switch_on'
      entity = args[0]
      service_call('switch', 'turn_on', entity)
    when 'switch_off'
      entity = args[0]
      service_call('switch', 'turn_off', entity)
    when 'dimmer_on'
      entity = args[0]
      service_call('light', 'turn_on', entity)
    when 'dimmer_off'
      entity = args[0]
      service_call('light', 'turn_off', entity)
    when 'dimmer_set'
      entity = args[0]
      pct = (args[1] || '0').to_f
      # HA expects brightness_pct 0..100
      service_call('light', 'turn_on', entity, { brightness_pct: pct })
    when 'shade_set'
      entity = args[0]
      pos = (args[1] || '0').to_i
      service_call('cover', 'set_cover_position', entity, { position: pos })
    when 'lock_lock'
      entity = args[0]
      service_call('lock', 'lock', entity)
    when 'unlock_lock'
      entity = args[0]
      service_call('lock', 'unlock', entity)
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
      log(:debug, :unhandled_action, cmd, args)
    end
  end

  private

  def service_call(domain, service, entity, service_data = nil)
    return if entity.to_s.strip.empty?

    log(:info, :ha_service_call, domain, service, entity, service_data || {})
    @ha.call_service(domain: domain, service: service, entity_id: entity, service_data: service_data)
  end

  def request_state_refresh(entity_ids)
    # subscribe_entities usually sends an initial snapshot, but when HA is under load
    # or during reconnect, Savant UI can stay stale. Force a get_states once.
    # NOTE: HA WebSocket get_states returns all entities; we filter in proxy.

    @ha.send(:send_json, { type: 'get_states' })
  rescue StandardError
    # ignore
  end

  def handle_ha_event(msg)
    ev = msg['event'] || {}
    # For subscribe_entities, payload includes:
    # - "a" full snapshot
    # - "c" changes with "+" patches
    data = ev['a'] || {}
    changes = ev['c'] || {}

    # snapshot
    data.each do |entity_id, packed|
      forward_entity(entity_id, packed)
    end

    # changes
    changes.each do |entity_id, diff|
      if diff.is_a?(Hash) && diff['+'].is_a?(Hash)
        packed = diff['+']
        forward_entity(entity_id, packed)
      end
    end
  rescue StandardError => e
    log(:error, :ha_event_error, e.class.name, e.message)
  end

  def forward_entity(entity_id, packed)
    # packed keys:
    # - 's' => state
    # - 'a' => attributes hash
    # We forward per-client filters.

    state = packed['s']
    attrs = packed['a'] || {}

    @clients.each_value do |client|
      next unless client.subscribed_to?(entity_id)

      client.filter.each do |k|
        case k
        when 'state'
          client.send_update(entity_id, 'state', state) unless state.nil?
        when 'attributes'
          client.send_update(entity_id, 'attributes', JSON.generate(attrs))
        else
          # attributes like brightness, temperature, current_temperature, preset_mode, current_position...
          v = attrs[k]
          # normalize numbers
          v = v.to_f if v.is_a?(Numeric)
          client.send_update(entity_id, k, v) unless v.nil?
        end
      end

      # HVAC UI often needs hvac_mode even if the filter only asked for 'state'.
      # Some integrations expose hvac_mode inside attributes; we mirror it to state key when present.
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
if token.to_s.strip.empty?
  warn 'Missing SUPERVISOR_TOKEN/HASS_TOKEN env var'
end

address = ENV['HASS_WS'] || HaWs::DEFAULT_WS
port = (ENV['SAVANT_TCP_PORT'] || '8080').to_i
bind = ENV['SAVANT_BIND'] || '0.0.0.0'

EM.run do
  proxy = HassProxy.new(token: token, address: address)
  proxy.start

  EM.start_server(bind, port, SavantConn, proxy)
  log(:info, :server_started, port)
end
