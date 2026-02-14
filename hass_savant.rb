#!/usr/bin/env ruby
# frozen_string_literal: true

# Savant <-> Home Assistant TCP proxy (multi-profile)
# Goals:
# - Multiple Savant profiles can connect simultaneously (lights, HVAC, locks, shades)
# - Single HA WebSocket shared across all clients
# - Stable per-profile identity (uses Savant-provided 8-hex prefix when present) so
#   filters/subscriptions survive Savant host restarts/reconnects
# - Monotonic HA request IDs (avoids id_reuse) + reconnect queue
# - Quiet logs by default (LOG_LEVEL=info|debug)

require 'json'
require 'eventmachine'
require 'faye/websocket'
require 'securerandom'
require 'socket'
require 'thread'

# -------------------------
# Logging
# -------------------------
LOG_LEVEL = (ENV['LOG_LEVEL'] || 'info').downcase
LEVELS = { 'debug' => 10, 'info' => 20, 'warn' => 30, 'error' => 40 }.freeze
LOG_NUM = LEVELS.fetch(LOG_LEVEL, 20)

def log(level, *args)
  lvl = LEVELS.fetch(level.to_s, 20)
  return if lvl < LOG_NUM

  $stdout.sync = true
  p([level.to_sym, *args])
end

# -------------------------
# HA WebSocket client
# -------------------------
class HaWs
  DEFAULT_WS = 'ws://supervisor/core/api/websocket'
  RESUB_CHUNK = 200

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

    # Track in-flight get_states requests so we can recognize the large
    # (all-entities) response and safely route it.
    @pending_get_states = {}

    @on_event = nil
    @on_ready = nil
  end

  attr_reader :subscribed_entities

  def on_event(&blk) = (@on_event = blk)
  def on_ready(&blk) = (@on_ready = blk)

  def start = connect

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

    # Clear in-flight bookkeeping on stop/restart
    @pending_get_states.clear
  end

  def ready? = @ws_ready

  def ensure_subscribed(entity_ids)
    ids = Array(entity_ids).compact.map(&:to_s).map(&:strip).reject(&:empty?)
    return if ids.empty?

    new_ids = ids.reject { |e| @subscribed_entities[e] }
    return if new_ids.empty?

    new_ids.each { |e| @subscribed_entities[e] = true }

    log(:info, :ha_subscribe, new_ids.length)
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

  def get_states
    id = next_id
    @pending_get_states[id] = true
    send_json(type: 'get_states', id: id)
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
      begin
        pl = payload.dup
        pl[:id] ||= next_id
        json = JSON.generate(pl)
        @ws.send(json)
        log(:debug, :ws_send, json)
      rescue StandardError => e
        log(:error, :ws_send_error, e.class.name, e.message)
      end
    end

    ptype = payload.is_a?(Hash) ? (payload[:type] || payload['type']) : nil

    # Auth must be sent before ws_ready, otherwise we deadlock.
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
    log(:info, :connecting_to, @address)

    @ws_ready = false
    @ws = Faye::WebSocket::Client.new(@address)

    @ws.on(:open) do |_|
      log(:info, :ws_connected)
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
      log(:warn, :ws_disconnected, event.code, event.reason)
      @ws_ready = false
      @ws = nil
      schedule_reconnect
    end

    @ws.on(:error) do |event|
      msg = event.respond_to?(:message) ? event.message : event.to_s
      log(:error, :ws_error, msg)
    end
  rescue StandardError => e
    log(:error, :ws_connect_error, e.class.name, e.message)
    schedule_reconnect
  end

  def schedule_reconnect
    return if @reconnect_timer

    @reconnect_attempt += 1
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
    log(:debug, :ws_recv, msg)

    case msg['type']
    when 'auth_required'
      send_json(type: 'auth', access_token: @token)
    when 'auth_ok'
      @ws_ready = true
      log(:info, :ha_ready)
      restore_subscriptions
      flush_queue
      @on_ready&.call
    when 'event'
      @on_event&.call(msg)
    when 'pong'
      log(:debug, :pong)
when 'result'
  if msg['success']
    # If this was a get_states snapshot we requested, convert the array of states
    # into our compact packed format and hand to the proxy as a synthetic event.
	    if @pending_get_states && @pending_get_states.delete(msg['id']) && msg['result'].is_a?(Array)
      states = {}
      msg['result'].each do |st|
        eid = st['entity_id']
        next unless eid
        states[eid] = { 's' => st['state'], 'a' => (st['attributes'] || {}) }
      end
      @on_event&.call({ 'type' => 'get_states', 'states' => states })
    end
  else
    log(:error, :request_failed, msg)
  end
    end
  end

  def restore_subscriptions
    ids = @subscribed_entities.keys
    log(:info, :restoring_subscriptions, ids.length)
    return if ids.empty?

    ids.each_slice(RESUB_CHUNK) do |chunk|
      send_json(type: 'subscribe_entities', entity_ids: chunk)
    end
  end
end

# -------------------------
# Savant TCP connection
# -------------------------
class SavantConn < EM::Connection
  attr_reader :client_key, :profile_id

  def initialize(proxy)
    super()
    @proxy = proxy
    @buf = +''
    @client_key = SecureRandom.hex(4) # per-connection key
    @profile_id = nil                # stable per Savant profile (8hex from Savant lines)

    @filter = ['state']
    @subs = {}
    @subscribe_all = false
    @bound = false
  end

  def post_init
    peer = begin
      Socket.unpack_sockaddr_in(get_peername).reverse
    rescue StandardError
      ['unknown', 0]
    end
    log(:info, :client_connected, peer, @client_key)
    @proxy.register_client(self)
  end

  def unbind
    log(:info, :client_disconnected, (@profile_id || @client_key))
    @proxy.unregister_client(self)
  end

  def receive_data(data)
    @buf << data
    # Savant uses \n, sometimes CRLF; accept both
    while (idx = @buf.index("\n"))
      raw = @buf.slice!(0, idx + 1)
      line = raw.strip
      next if line.empty?
      handle_line(line)
    end
  rescue StandardError => e
    log(:error, :savant_receive_error, e.class.name, e.message)
  end

  def send_update(entity_id, key, value)
    send_data("#{entity_id}_#{key}===#{value}\n")
  rescue StandardError => e
    log(:error, :savant_send_error, e.class.name, e.message)
  end

  def subscribed_to?(entity_id)
    @subscribe_all || @subs[entity_id]
  end

  def filter = @filter
  def subscriptions = @subs.keys

  # Called by proxy when we learn/confirm the stable profile_id
  def bind_profile!(pid, restore: nil)
    @profile_id = pid
    return if @bound

    @bound = true
    return unless restore

    if restore[:filter]&.any?
      @filter = restore[:filter]
      log(:info, :filter_restored, @profile_id, @filter)
    end

    if restore[:subs]&.any?
      restore[:subs].each { |e| @subs[e] = true }
      log(:info, :subs_restored, @profile_id, restore[:subs].length)
      @proxy.ensure_ha_subscribed(restore[:subs])
    end
  end

  def current_identity
    @profile_id || @client_key
  end


  # Back-compat: some proxy versions expect `identity` (profile_id when known, else client_key).
  def identity
    current_identity
  end

  private

  def handle_line(line)
    parts = line.split(',')
    pid = nil
    if parts[0] =~ /^[0-9a-f]{8}$/i && parts.length >= 2
      pid = parts[0].downcase
      cmd = parts[1]
      args = parts[2..]
    else
      cmd = parts[0]
      args = parts[1..]
    end

    # As soon as we see a Savant profile id, bind it (stable identity)
    if pid && !@profile_id
      @proxy.bind_profile(self, pid)
    end

    log(:debug, :from_savant, (pid || @client_key), line)

    case cmd
    when 'hello', 'heartbeat'
      # ignore
    when 'state_filter'
      @filter = args.join(',').split(',').map(&:strip).reject(&:empty?)
      @filter = ['state'] if @filter.empty?
      @proxy.save_filter(current_identity, @filter)
    when 'subscribe_all_events'
      @subscribe_all = (args.first.to_s.strip.upcase == 'YES')
      @proxy.save_subs(current_identity, subscribe_all: @subscribe_all)
    when 'subscribe_entity'
      ids = args.join(',').split(',').map(&:strip).reject(&:empty?)
      if ids.empty?
        # Savant sometimes reconnects and sends an empty subscribe_entity.
        # In that case, restore the last known subscription set for this profile/filter.
        @proxy.restore_subs_if_empty(current_identity)
        return
      end

      ids.each { |e| @subs[e] = true }
      @proxy.save_subs(current_identity, add: ids)
      @proxy.on_client_subscribe(current_identity, ids)
    else
      @proxy.handle_action(cmd, args)
    end
  end
end

# -------------------------
# Main proxy
# -------------------------
class HassProxy
  REFRESH_COOLDOWN = 1.0 # seconds (avoid get_states spam)

  def initialize(token:, address: HaWs::DEFAULT_WS)
    @clients = {} # conn_id => conn
    @profiles = {}
    @last_filter_value = {} # identity/profile_id => {filter:[], subs:{}, subscribe_all:bool}
    @entity_cache = {} # entity_id => packed
    @subs_by_sig = {} # filter signature => subs hash
    @identity_to_sig = {}
    @sig_to_identity = {}
    @last_refresh_at = 0.0

    @ha = HaWs.new(token: token, address: address)
    @ha.on_event { |msg| handle_ha_event(msg) }
    @ha.on_ready { refresh_all_profiles }
  end

  def start = @ha.start

  def register_client(conn)
    @clients[conn.identity] = conn
  end

  def unregister_client(conn)
    @clients.delete(conn.identity)
    # keep profile memory; do NOT stop HA
  end

  def bind_profile(conn, profile_id)
    prof = (@profiles[profile_id] ||= { filter: ['state'], subs: {}, subscribe_all: false })

    # Re-key the live connection from its transient client_key to the stable Savant profile_id
    if @clients[conn.client_key] == conn
      @clients.delete(conn.client_key)
    end
    @clients[profile_id] = conn

    conn.bind_profile!(profile_id, restore: { filter: prof[:filter], subs: prof[:subs].keys })

    # Prime UI immediately from cache + force one refresh
    replay_cached(profile_id)
    request_state_refresh
  end

  def save_filter(identity, filter)
    prof = (@profiles[identity] ||= { filter: ['state'], subs: {}, subscribe_all: false })
    prof[:filter] = filter

    sig = Array(filter).map(&:to_s).map(&:strip).reject(&:empty?).sort.join(',')
    @identity_to_sig[identity] = sig

    # Persist last known subs per filter signature (fallback when Savant reconnects with empty subscribe_entity)
    @subs_by_sig[sig] = prof[:subs].dup unless prof[:subs].empty?

    prev_id = @sig_to_identity[sig]
    if prev_id && prev_id != identity
      prev = @profiles[prev_id]
      # Try restore from previous identity or signature store
      restored = nil
      if prev && prev[:subs] && !prev[:subs].empty?
        restored = prev[:subs]
      elsif @subs_by_sig[sig] && !@subs_by_sig[sig].empty?
        restored = @subs_by_sig[sig]
      end

      if restored && prof[:subs].empty?
        prof[:subs] = restored.dup
        @subs_by_sig[sig] = prof[:subs].dup
        log(:info, :subs_restored_by_filter, sig, prof[:subs].length)
        @ha.ensure_subscribed(prof[:subs].keys)
        replay_cached(identity)
        request_state_refresh
      end
    end

    @sig_to_identity[sig] = identity
    prev = @last_filter_value[identity]
    if prev != filter
      @last_filter_value[identity] = filter
      log(:info, :filter_set, identity, filter)
    end
  end

def save_subs(identity, add: nil, subscribe_all: nil)
    prof = (@profiles[identity] ||= { filter: ['state'], subs: {}, subscribe_all: false })
    if subscribe_all != nil
      prof[:subscribe_all] = !!subscribe_all
    end
    Array(add).each { |e| prof[:subs][e] = true } if add

    # keep signature store updated
    sig = @identity_to_sig[identity]
    @subs_by_sig[sig] = prof[:subs].dup if sig && !prof[:subs].empty?
  end

  def restore_subs_if_empty(identity)
    prof = (@profiles[identity] ||= { filter: ['state'], subs: {}, subscribe_all: false })
    return false unless prof[:subs].empty? && !prof[:subscribe_all]

    sig = @identity_to_sig[identity]
    stored = sig ? @subs_by_sig[sig] : nil
    return false unless stored && !stored.empty?

    prof[:subs] = stored.dup
    log(:info, :subs_restored, identity, prof[:subs].length)
    @ha.ensure_subscribed(prof[:subs].keys)
    replay_cached(identity)
    request_state_refresh
    true
  end


  def on_client_subscribe(identity, entity_ids)
    ensure_ha_subscribed(entity_ids)
    # Even if HA was already subscribed globally, new Savant profiles need an immediate
    # snapshot so their UI doesn't stay stale until the next HA state change.
    replay_cached(identity, only: entity_ids)
  end

def ensure_ha_subscribed(entity_ids)
    @ha.ensure_subscribed(entity_ids)
    request_state_refresh
  end

  def handle_action(cmd, args)
    case cmd
    when 'socket_on'  then service_call('switch', 'turn_on',  args[0])
    when 'socket_off' then service_call('switch', 'turn_off', args[0])
    when 'switch_on'  then service_call('switch', 'turn_on',  args[0])
    when 'switch_off' then service_call('switch', 'turn_off', args[0])

    when 'dimmer_on'  then service_call('light', 'turn_on',  args[0])
    when 'dimmer_off' then service_call('light', 'turn_off', args[0])
    when 'dimmer_set'
      entity = args[0]
      pct = (args[1] || '0').to_f
      service_call('light', 'turn_on', entity, { brightness_pct: pct })

    when 'shade_set'
      entity = args[0]
      pos = (args[1] || '0').to_i
      service_call('cover', 'set_cover_position', entity, { position: pos })

    when 'lock_lock'   then service_call('lock', 'lock',   args[0])
    when 'unlock_lock' then service_call('lock', 'unlock', args[0])

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

  def replay_cached(identity, only: nil)
    prof = @profiles[identity]
    return unless prof && !prof[:subs].empty?

    client = @clients[identity]
    return unless client

    prof[:subs].keys.each do |entity_id|
      packed = @entity_cache[entity_id]
      next unless packed
      forward_entity_to_client(client, entity_id, packed, prof[:filter])
    end
  end

  def service_call(domain, service, entity, service_data = nil)
    return if entity.to_s.strip.empty?

    log(:info, :ha_service_call, domain, service, entity, service_data || {})
    @ha.call_service(domain: domain, service: service, entity_id: entity, service_data: service_data)
  end

  def request_state_refresh
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if (now - @last_refresh_at) < REFRESH_COOLDOWN

    @last_refresh_at = now
    @ha.get_states
  rescue StandardError
    # ignore
  end

  def refresh_all_profiles
    # After HA reconnect, force a refresh so every Savant profile gets a snapshot.
    request_state_refresh
  end

  def handle_ha_event(msg)
    if msg['type'] == 'get_states' && msg['states'].is_a?(Hash)
      msg['states'].each { |eid, packed| forward_entity(eid, packed) }
      return
    end

    ev = msg['event'] || {}

    # subscribe_entities events:
    # - "a": full snapshot for subscribed entities
    # - "c": delta patches
    data = ev['a'] || {}
    changes = ev['c'] || {}

    data.each { |entity_id, packed| forward_entity(entity_id, packed) }

    changes.each do |entity_id, diff|
      next unless diff.is_a?(Hash) && diff['+'].is_a?(Hash)
      forward_entity(entity_id, diff['+'])
    end
  rescue StandardError => e
    log(:error, :ha_event_error, e.class.name, e.message)
  end

  def forward_entity(entity_id, packed)
    # cache last known state so a newly-connected Savant profile can be primed immediately
    @entity_cache[entity_id] = packed

    @clients.each_value do |client|
      next unless client.subscribed_to?(entity_id)

      # use the *profile* filter if we have it (so we can restore by signature accurately)
      identity = client.respond_to?(:identity) ? client.identity : client.client_key
      prof = @profiles[identity]
      filter = prof ? prof[:filter] : client.filter

      forward_entity_to_client(client, entity_id, packed, filter)
    end
  end

  def forward_entity_to_client(client, entity_id, packed, filter)
    state = packed['s']
    attrs = packed['a'] || {}

    Array(filter).each do |k|
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

    # HVAC UI helpers (some XMLs bind to these explicitly)
    if entity_id.start_with?('climate.')
      hvac_mode = attrs['hvac_mode']
      hvac_action = attrs['hvac_action']
      client.send_update(entity_id, 'hvac_mode', hvac_mode) if hvac_mode
      client.send_update(entity_id, 'hvac_action', hvac_action) if hvac_action
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
  log(:info, :server_started, port, { bind: bind, ha: address, log_level: LOG_LEVEL })
end
