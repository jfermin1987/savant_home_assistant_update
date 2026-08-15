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
require 'fileutils'
require 'time'

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
# Persistent Savant numeric-ID registry
# -------------------------
class EntityIdRegistry
  # Global 3-digit Savant addresses, grouped by subsystem.
  # The mapping is persistent: once an entity gets an ID, it is never renumbered
  # automatically. This mirrors the proven Ezlo profile strategy.
  RANGES = {
    'lighting' => (1..299),
    'hvac'     => (300..399),
    'fan'      => (400..499),
    'lock'     => (500..599),
    'garage'   => (600..699),
    'shade'    => (700..899)
  }.freeze

  CATEGORY_ORDER = RANGES.keys.freeze

  attr_reader :path

  def self.default_path
    candidates = [
      ENV['SAVANT_ENTITY_MAP_FILE'],
      '/data/savant_entity_ids.json',
      '/config/savant_entity_ids.json',
      '/tmp/savant_entity_ids.json'
    ].compact.reject(&:empty?)

    candidates.each do |candidate|
      begin
        dir = File.dirname(candidate)
        FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
        return candidate if File.writable?(dir)
      rescue StandardError
        next
      end
    end

    '/tmp/savant_entity_ids.json'
  end

  def initialize(path: self.class.default_path)
    @path = path
    @entries = {}       # entity_id => metadata
    @id_to_entity = {}  # "001" => entity_id

    if ENV['RESET_SAVANT_ENTITY_MAP'].to_s == '1' && File.file?(@path)
      File.delete(@path)
      log(:warn, :entity_id_registry_reset, @path)
    end

    load!
    log(:info, :entity_id_registry_path, @path)
  end

  def resolve(value)
    key = normalize_id(value)
    return @id_to_entity[key] if key && @id_to_entity[key]

    value.to_s.strip
  end

  def id_for(entity_id)
    e = @entries[entity_id.to_s]
    e && format('%03d', e['id'].to_i)
  end

  def entries
    @entries.values.sort_by { |e| e['id'].to_i }
  end

  def refresh(states)
    changed = false
    now = Time.now.utc.iso8601
    seen = {}

    candidates = states.map do |entity_id, packed|
      attrs = packed.is_a?(Hash) ? (packed['a'] || {}) : {}
      category = classify_category(entity_id, attrs)
      next unless category

      eid = entity_id.to_s
      seen[eid] = true

      {
        'entity_id' => eid,
        'category' => category,
        'device_type' => classify_device_type(entity_id, attrs),
        'friendly_name' => (attrs['friendly_name'] || entity_id).to_s,
        'device_class' => attrs['device_class'].to_s,
        'active' => true,
        'last_seen' => now
      }
    end.compact

    # Deterministic first assignment: category, then HA entity_id.
    candidates.sort_by { |c| [CATEGORY_ORDER.index(c['category']) || 999, c['entity_id']] }.each do |c|
      eid = c['entity_id']
      existing = @entries[eid]

      if existing
        # NEVER move an existing entity to another ID/range automatically.
        if existing['category'] && existing['category'] != c['category']
          log(:warn, :entity_category_changed_but_id_preserved,
              eid, :old, existing['category'], :new, c['category'], :id, existing['id'])
        end

        # Preserve the original category if it already exists; changing ranges
        # would invalidate Savant data tables/scenes.
        c['category'] = existing['category'] if existing['category']

        %w[category device_type friendly_name device_class active].each do |k|
          if existing[k] != c[k]
            existing[k] = c[k]
            changed = true
          end
        end
        existing['last_seen'] = now
        next
      end

      id = next_free_id(c['category'])
      unless id
        log(:error, :entity_id_range_full, c['category'], eid)
        next
      end

      @entries[eid] = c.merge('id' => id)
      @id_to_entity[format('%03d', id)] = eid
      changed = true
      log(:info, :entity_id_assigned,
          format('%03d', id), c['category'], c['device_type'], eid)
    end

    # Do not recycle IDs when entities disappear. Mark them missing so System
    # State makes stale mappings obvious instead of silently reusing the address.
    @entries.each do |eid, e|
      next if seen[eid]
      next if e['active'] == false

      e['active'] = false
      changed = true
      log(:warn, :entity_id_marked_missing, format('%03d', e['id'].to_i), eid)
    end

    rebuild_reverse!
    save! if changed
    changed
  end

  def catalog_rows
    entries.map do |e|
      {
        id: format('%03d', e['id'].to_i),
        entity_id: e['entity_id'],
        category: e['category'],
        device_type: (e['device_type'] || fallback_device_type(e)).to_s,
        friendly_name: e['friendly_name'].to_s,
        active: e['active'] != false,
        value: catalog_value(e)
      }
    end
  end

  def counts
    h = Hash.new(0)
    entries.each do |e|
      next if e['active'] == false
      h[(e['device_type'] || fallback_device_type(e)).to_s] += 1
    end
    h
  end

  private

  def normalize_id(value)
    s = value.to_s.strip
    return nil unless s.match?(/\A\d{1,3}\z/)

    format('%03d', s.to_i)
  end

  def classify_category(entity_id, attrs)
    domain = entity_id.to_s.split('.', 2).first
    case domain
    when 'light', 'switch'
      'lighting'
    when 'climate'
      'hvac'
    when 'fan'
      'fan'
    when 'lock'
      'lock'
    when 'cover'
      dc = attrs['device_class'].to_s.downcase
      %w[garage gate].include?(dc) ? 'garage' : 'shade'
    else
      nil
    end
  end

  def classify_device_type(entity_id, attrs)
    domain = entity_id.to_s.split('.', 2).first

    case domain
    when 'switch'
      'switch'
    when 'light'
      modes = Array(attrs['supported_color_modes']).map { |m| m.to_s.downcase }
      dimmable = attrs.key?('brightness') || modes.any? { |m| m != 'onoff' }
      dimmable ? 'dimmer' : 'switch'
    when 'climate'
      'thermostat'
    when 'fan'
      'fan'
    when 'lock'
      'lock'
    when 'cover'
      dc = attrs['device_class'].to_s.downcase
      %w[garage gate].include?(dc) ? 'garage' : 'shade'
    else
      domain
    end
  end

  def fallback_device_type(e)
    case e['category']
    when 'lighting' then e['entity_id'].to_s.start_with?('light.') ? 'dimmer' : 'switch'
    when 'hvac' then 'thermostat'
    else e['category']
    end
  end

  def next_free_id(category)
    range = RANGES.fetch(category)
    used = @entries.values.map { |e| e['id'].to_i }.to_h { |id| [id, true] }
    range.find { |id| !used[id] }
  end

  def catalog_value(e)
    id_type = (e['device_type'] || fallback_device_type(e)).to_s.upcase
    status = e['active'] == false ? "MISSING/#{id_type}" : id_type
    friendly = e['friendly_name'].to_s.gsub(/[\r\n]+/, ' ').strip
    entity = e['entity_id'].to_s.gsub(/[\r\n]+/, ' ').strip
    [status, entity, friendly].reject(&:empty?).join(' | ')
  end

  def rebuild_reverse!
    @id_to_entity = {}
    @entries.each do |eid, e|
      id = e['id'].to_i
      next if id <= 0
      @id_to_entity[format('%03d', id)] = eid
    end
  end

  def load!
    return unless File.file?(@path)

    raw = JSON.parse(File.read(@path))
    data = raw['entities'].is_a?(Hash) ? raw['entities'] : {}
    @entries = data
    rebuild_reverse!
    log(:info, :entity_id_registry_loaded, @entries.length, @path)
  rescue StandardError => e
    log(:error, :entity_id_registry_load_error, @path, e.class.name, e.message)
    @entries = {}
    @id_to_entity = {}
  end

  def save!
    dir = File.dirname(@path)
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

    payload = {
      'version' => 2,
      'updated_at' => Time.now.utc.iso8601,
      'entities' => @entries
    }
    tmp = "#{@path}.tmp"
    File.write(tmp, JSON.pretty_generate(payload))
    File.rename(tmp, @path)
    log(:info, :entity_id_registry_saved, @entries.length, @path)
  rescue StandardError => e
    log(:error, :entity_id_registry_save_error, @path, e.class.name, e.message)
  end
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

    # HA requires monotonically increasing request ids per WS connection.
    # We'll start at a high random base each time we authenticate to avoid
    # edge-cases during HA restarts.
    @next_id = 0
    @id_mutex = Mutex.new

    @send_queue = []
    @reconnect_attempt = 0
    @reconnect_timer = nil
    @ping_timer = nil

    @subscribed_entities = {} # entity_id => true

    # In-flight request bookkeeping: id => payload hash (as sent)
    @inflight = {}

    # Track in-flight get_states requests so we can recognize the large response.
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
    @inflight.clear
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
    send_json(type: 'get_states', _track_get_states: true)
  end

  private

  def next_id
    @id_mutex.synchronize do
      @next_id += 1
      @next_id
    end
  end

  def set_id_base!
    # Ensure id base is "high" and monotonically increasing even across reconnects.
    base = (Time.now.to_i % 1_000_000) * 1000 + rand(1000)
    @id_mutex.synchronize do
      @next_id = [@next_id, base].max
    end
    log(:warn, :id_base_set, @next_id) if LOG_NUM <= LEVELS['warn']
  end

  def track_inflight!(pl)
    return unless pl.is_a?(Hash)
    id = pl[:id] || pl['id']
    return unless id
    @inflight[id] = pl
    if pl[:_track_get_states]
      @pending_get_states[id] = true
    end
  end

  def untrack_inflight!(id)
    @inflight.delete(id) if id
    @pending_get_states.delete(id) if id
  end

  def resend_with_new_id!(old_id)
    payload = @inflight.delete(old_id)
    @pending_get_states.delete(old_id)

    return unless payload

    # Remove internal tracking key
    payload = payload.dup
    payload.delete(:_track_get_states)

    # Bump id far ahead and resend with new id
    new_id = nil
    @id_mutex.synchronize do
      @next_id = [@next_id, old_id.to_i + 1000].max
      @next_id += 1
      new_id = @next_id
    end

    payload[:id] = new_id
    track_inflight!(payload.merge(_track_get_states: false))
    json = JSON.generate(payload)
    @ws&.send(json)
    log(:warn, :id_reuse_retry, old_id, :new_id, new_id, :type, (payload[:type] || payload['type']))
  rescue StandardError => e
    log(:error, :id_reuse_retry_failed, e.class.name, e.message)
  end

  def send_json(payload)
    op = lambda do
      begin
        pl = payload.dup

        # Internal marker (not part of HA protocol) to track get_states
        track_get_states = !!pl.delete(:_track_get_states)

        pl[:id] ||= next_id
        track_inflight!(pl.merge(_track_get_states: track_get_states))

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
      # Clear in-flight; HA will have dropped these anyway.
      @inflight.clear
      @pending_get_states.clear
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
      # Reset id base for the NEW authenticated session so HA never sees low ids
      set_id_base!

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
      id = msg['id']
      if msg['success']
        # get_states returns an array of full states; convert to packed form and synthesize an event
        if @pending_get_states.delete(id) && msg['result'].is_a?(Array)
          states = {}
          msg['result'].each do |st|
            eid = st['entity_id']
            next unless eid
            states[eid] = { 's' => st['state'], 'a' => (st['attributes'] || {}) }
          end
          @on_event&.call({ 'type' => 'get_states', 'states' => states })
        end
        untrack_inflight!(id)
      else
        if msg.dig('error', 'code') == 'id_reuse'
          # Bump and retry the request that failed (important for subscribe_entities right after HA restart)
          resend_with_new_id!(id)
        else
          untrack_inflight!(id)
        end
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
    @catalog_ready = false
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
    savant_id = @proxy.savant_id_for(entity_id) || entity_id
    send_data("#{savant_id}_#{key}===#{value}\n")
  rescue StandardError => e
    log(:error, :savant_send_error, e.class.name, e.message)
  end

  def send_catalog_mapping(id, entity_id)
    # Mirror Ezlo's proven DeviceID map: store ONLY the raw HA entity_id.
    # This keeps System State values directly valid for Home Assistant.
    safe = entity_id.to_s.gsub(/[
]+/, '').strip
    send_data("haid:#{id},#{safe}
")
  rescue StandardError => e
    log(:error, :savant_catalog_send_error, e.class.name, e.message)
  end

  def send_catalog_summary(value)
    safe = value.to_s.gsub(/[
]+/, ' ').strip
    send_data("hacatalog:#{safe}
")
  rescue StandardError => e
    log(:error, :savant_catalog_send_error, e.class.name, e.message)
  end

  def catalog_ready? = @catalog_ready

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

      # state_filter is emitted by this profile after the TCP session is usable.
      # Treat only the FIRST one per connection as catalog-ready; the XML repeats
      # state_filter every 15s as a keepalive and must not trigger catalog floods.
      unless @catalog_ready
        @catalog_ready = true
        @proxy.on_client_ready(current_identity)
      end
    when 'catalog_refresh'
      log(:info, :manual_catalog_refresh_requested, current_identity)
      @proxy.refresh_catalog(current_identity)
    when 'subscribe_all_events'
      @subscribe_all = (args.first.to_s.strip.upcase == 'YES')
      @proxy.save_subs(current_identity, subscribe_all: @subscribe_all)
    when 'subscribe_entity'
      ids = args.join(',').split(',').map(&:strip).reject(&:empty?)
      if ids.empty?
        # Savant sometimes reconnects and sends an empty subscribe_entity.
        @proxy.restore_subs_if_empty(current_identity)
        return
      end

      canonical_ids = ids.map { |requested| @proxy.resolve_entity(requested) }
      canonical_ids.each { |e| @subs[e] = true }
      @proxy.save_subs(current_identity, add: canonical_ids)
      @proxy.on_client_subscribe(current_identity, canonical_ids)
    else
      # Safety net: opportunistically subscribe to the entity we're controlling
      # so its state feedback flows even if the periodic subscribe handshake
      # hasn't populated this profile yet (e.g. right after a host reboot, where
      # Savant connects to the proxy faster than it delivers the entity list).
      target = @proxy.resolve_entity(args[0])
      if target.include?('.') && !@subs[target]
        @subs[target] = true
        @proxy.save_subs(current_identity, add: [target])
        @proxy.on_client_subscribe(current_identity, [target])
      end
      @proxy.handle_action(cmd, args)
    end
  end
end

# -------------------------
# Main proxy
# -------------------------
class HassProxy
  REFRESH_COOLDOWN = 1.0 # seconds (avoid get_states spam)

  # States that mean "the load is off" for feedback purposes. When an entity is
  # in one of these, level-type attributes must be reported as 0 so dimmer/shade
  # tiles in Savant actually collapse instead of keeping their last value.
  OFF_STATES = %w[off unavailable unknown closed none].freeze

  # Attributes that represent a level/position and should be zeroed on OFF.
  LEVEL_KEYS = %w[brightness brightness_pct level value current_position position].freeze

  def initialize(token:, address: HaWs::DEFAULT_WS)
    @entity_ids = EntityIdRegistry.new

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
    @ha.on_ready { on_ha_ready }
  end

  def start = @ha.start

  def resolve_entity(value)
    raw = value.to_s.strip

    # Backward-compatible cleanup for v6/v6.1 catalog strings, e.g.:
    # entity:SWITCH | switch.bano_principal_1 | Luz Bano
    raw = raw.sub(/\Aentity:/i, '').strip
    if raw.include?('|')
      candidate = raw.split('|').map(&:strip).find do |part|
        part.match?(/\A(?:switch|light|climate|fan|lock|cover)\.[A-Za-z0-9_]+\z/)
      end
      return candidate if candidate
    end

    @entity_ids.resolve(raw)
  end

  def savant_id_for(entity_id)
    @entity_ids.id_for(entity_id)
  end

  def refresh_catalog(identity = nil)
    request_discovery(identity, reason: :manual)
  end

  def on_client_ready(identity)
    # First state_filter on a fresh Savant TCP session = host/profile online.
    # Run one fresh HA inventory discovery here and nowhere periodically.
    log(:info, :catalog_client_ready, identity, :known_ids, @entity_ids.entries.length)
    request_discovery(identity, reason: :savant_connect)
  end

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

    # Prime normal UI from local cache. The first state_filter on this fresh
    # TCP session triggers the one-time discovery.
    replay_cached(profile_id)
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
    true
  end


  def on_client_subscribe(identity, entity_ids)
    ensure_ha_subscribed(entity_ids)
    # Even if HA was already subscribed globally, new Savant profiles need an immediate
    # snapshot so their UI doesn't stay stale until the next HA state change.
    replay_cached(identity, only: entity_ids)
  end

def ensure_ha_subscribed(entity_ids)
    # subscribe_entities provides the initial snapshot for these entities.
    @ha.ensure_subscribed(entity_ids)
  end

  def handle_action(cmd, args)
    args = Array(args).dup
    args[0] = resolve_entity(args[0]) unless args.empty?

    case cmd
    when 'socket_on'  then service_call('switch', 'turn_on',  args[0])
    when 'socket_off' then service_call('switch', 'turn_off', args[0])
    when 'switch_on'  then service_call('switch', 'turn_on',  args[0])
    when 'switch_off' then service_call('switch', 'turn_off', args[0])

    when 'dimmer_on'  then service_call('light', 'turn_on',  args[0])
    when 'dimmer_off' then service_call('light', 'turn_off', args[0])
    when 'dimmer_set'
      entity = args[0]
      pct = [[(args[1] || '0').to_f, 0].max, 100].min

      if entity.to_s.start_with?('switch.')
        service_call('switch', pct <= 0 ? 'turn_off' : 'turn_on', entity)
      elsif pct <= 0
        service_call('light', 'turn_off', entity)
      else
        service_call('light', 'turn_on', entity, { brightness_pct: pct })
      end

    when 'fan_set'
      entity = args[0]
      raw = (args[1] || '0').to_f
      if raw <= 0
        service_call('fan', 'turn_off', entity)
      else
        pct = if raw <= 3
                { 1 => 33, 2 => 66, 3 => 100 }.fetch(raw.to_i, 100)
              elsif raw <= 7
                # Existing Savant XML commonly maps fan levels to 2/4/7.
                raw <= 2 ? 33 : (raw <= 4 ? 66 : 100)
              else
                [[raw, 1].max, 100].min.round
              end
        service_call('fan', 'set_percentage', entity, { percentage: pct })
      end

    when 'shade_set'
      entity = args[0]
      pos = (args[1] || '0').to_i
      service_call('cover', 'set_cover_position', entity, { position: pos })
    when 'shade_up', 'shade_open'
      service_call('cover', 'open_cover', args[0])
    when 'shade_down', 'shade_close'
      service_call('cover', 'close_cover', args[0])
    when 'shade_stop'
      service_call('cover', 'stop_cover', args[0])

    when 'open_garage_door'
      service_call('cover', 'open_cover', args[0])
    when 'close_garage_door'
      service_call('cover', 'close_cover', args[0])
    when 'toggle_garage_door'
      entity = args[0]
      current = @entity_cache.dig(entity, 's').to_s.downcase
      service_call('cover', current == 'open' ? 'close_cover' : 'open_cover', entity)

    when 'tv_key'
      entity = args[0]
      command = args[1].to_s.strip
      if command.empty?
        log(:warn, :tv_key_missing_command, entity)
      else
        service_call('remote', 'send_command', entity, { command: command })
      end

    when 'tv_power_on'
      # Preferred HA path for Android TV Remote. If the TV is in deep sleep and the
      # remote entity is unavailable, use WOL first or fall back to tv_key POWER.
      service_call('remote', 'turn_on', args[0])

    when 'tv_power_off'
      service_call('remote', 'turn_off', args[0])

    when 'tv_power_toggle'
      service_call('remote', 'send_command', args[0], { command: 'POWER' })

    when 'tv_launch_app'
      entity = args[0]
      activity = args[1].to_s.strip
      if activity.empty?
        log(:warn, :tv_launch_app_missing_activity, entity)
      else
        service_call('remote', 'turn_on', entity, { activity: activity })
      end

    when 'media_player_turn_on'
      service_call('media_player', 'turn_on', args[0])

    when 'media_player_turn_off'
      service_call('media_player', 'turn_off', args[0])

    when 'wol'
      send_wol(args[0])

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

  def replay_catalog(identity = nil)
    clients = if identity
                c = @clients[identity]
                c && c.catalog_ready? ? [c] : []
              else
                @clients.values.select(&:catalog_ready?)
              end
    return if clients.empty?

    rows = @entity_ids.catalog_rows
    counts = @entity_ids.counts
    summary = %w[switch dimmer thermostat fan lock garage shade].map do |k|
      "#{k}=#{counts[k] || 0}"
    end.join(' | ')

    log(:info, :catalog_replay,
        :target, (identity || 'all'),
        :clients, clients.length,
        :entries, rows.length,
        :summary, summary)

    clients.each { |client| client.send_catalog_summary(summary) }

    # Ezlo's proven profile deliberately paces ID registration. Do the same
    # asynchronously so EventMachine never blocks while Savant ingests the list.
    gap = [(ENV['SAVANT_CATALOG_ID_GAP'] || '0.03').to_f, 0.0].max
    rows.each_with_index do |row, idx|
      EM.add_timer(idx * gap) do
        clients.each do |client|
          next unless client.catalog_ready?
          client.send_catalog_mapping(row[:id], row[:entity_id])
        end
      end
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

  def send_wol(mac)
    mac = mac.to_s.strip
    return if mac.empty?

    clean = mac.delete(':-').downcase
    unless clean.match?(/\A[0-9a-f]{12}\z/)
      log(:warn, :wol_invalid_mac, mac)
      return
    end

    packet = [clean].pack('H*')
    magic = (0xff.chr.b * 6) + (packet * 16)

    UDPSocket.open do |sock|
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true)
      sock.send(magic, 0, '255.255.255.255', 9)
    end
    log(:info, :wol_sent, mac)
  rescue StandardError => e
    log(:error, :wol_error, mac, e.class.name, e.message)
  end

  def service_call(domain, service, entity, service_data = nil)
    return if entity.to_s.strip.empty?

    log(:info, :ha_service_call, domain, service, entity, service_data || {})
    @ha.call_service(domain: domain, service: service, entity_id: entity, service_data: service_data)
  end

  def request_discovery(identity = nil, reason: :manual)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if (now - @last_refresh_at) < REFRESH_COOLDOWN
      log(:debug, :catalog_discovery_deduped, identity, reason)
      return
    end

    @last_refresh_at = now
    @catalog_discovery_target = identity
    @catalog_discovery_reason = reason
    log(:info, :catalog_discovery_requested, :target, identity, :reason, reason)
    @ha.get_states
  rescue StandardError => e
    log(:error, :catalog_discovery_request_error, e.class.name, e.message)
  end

  def on_ha_ready
    # HA reconnects restore subscriptions inside HaWs, but intentionally do not
    # rebuild/rebroadcast the device catalog. Discovery belongs to Savant host
    # startup/profile reconnect, or the manual RefreshEntityCatalog action.
    log(:info, :ha_ready_no_discovery)
  end

  def handle_ha_event(msg)
    if msg['type'] == 'get_states' && msg['states'].is_a?(Hash)
      target = @catalog_discovery_target
      reason = @catalog_discovery_reason || :unknown
      @catalog_discovery_target = nil
      @catalog_discovery_reason = nil

      catalog_changed = @entity_ids.refresh(msg['states'])
      log(:info, :catalog_inventory_received,
          :reason, reason,
          :ha_states, msg['states'].length,
          :catalog_ids, @entity_ids.entries.length,
          :changed, catalog_changed)

      # Exactly one full catalog delivery for this discovery cycle.
      replay_catalog(target)

      # This same snapshot initializes subscribed Savant states after boot.
      msg['states'].each { |eid, packed| apply_full_state(eid, packed) }
      return
    end

    ev = msg['event'] || {}

    # subscribe_entities events:
    # - "a": full snapshot for (newly) subscribed entities
    # - "c": minimal delta patches ("+": added/changed fields, "-": removed)
    # - "r": entities removed from the registry
    (ev['a'] || {}).each { |entity_id, packed| apply_full_state(entity_id, packed) }

    (ev['c'] || {}).each do |entity_id, diff|
      next unless diff.is_a?(Hash)
      apply_delta(entity_id, diff)
    end

    if ev['r'].is_a?(Array)
      ev['r'].each { |entity_id| @entity_cache.delete(entity_id) }
    end
  rescue StandardError => e
    log(:error, :ha_event_error, e.class.name, e.message)
  end

  # Store a FULL state snapshot and forward it.
  def apply_full_state(entity_id, packed)
    full = { 's' => packed['s'], 'a' => (packed['a'] || {}) }
    @entity_cache[entity_id] = full
    forward_entity(entity_id, full)
  end

  # Merge a compressed delta onto the cached full state, then forward the
  # resulting full state.
  #
  # HA only sends the *changed* fields in "c" events, so we MUST merge into the
  # previous snapshot. We also honor "-": when a light/cover turns off, HA
  # removes brightness/position instead of setting them to 0, and those removals
  # arrive here. Ignoring them was why dimmers stayed "on" in the Savant UI.
  def apply_delta(entity_id, diff)
    prev = @entity_cache[entity_id] || { 's' => nil, 'a' => {} }
    merged = { 's' => prev['s'], 'a' => (prev['a'] || {}).dup }

    plus = diff['+']
    if plus.is_a?(Hash)
      merged['s'] = plus['s'] if plus.key?('s')
      merged['a'].merge!(plus['a']) if plus['a'].is_a?(Hash)
    end

    minus = diff['-']
    if minus.is_a?(Hash) && minus['a']
      Array(minus['a']).each { |k| merged['a'].delete(k) }
    end

    @entity_cache[entity_id] = merged
    forward_entity(entity_id, merged)
  end

  def forward_entity(entity_id, packed)
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

    # A light/cover that is off (or unavailable) has had its brightness/position
    # attributes REMOVED by HA, not zeroed. Normalize those to 0 here so any
    # level-bound UI element in Savant actually drops instead of keeping its last
    # value and looking like it's still on.
    off_like = state.nil? || OFF_STATES.include?(state.to_s.downcase)

    fkeys = Array(filter)

    fkeys.each do |k|
      case k
      when 'state'
        client.send_update(entity_id, 'state', state) unless state.nil?
      when 'attributes'
        client.send_update(entity_id, 'attributes', JSON.generate(attrs))
      when 'brightness'
        v = off_like ? 0 : attrs['brightness']
        client.send_update(entity_id, 'brightness', v) unless v.nil?
      when 'brightness_pct'
        # HA reports brightness on a 0-255 scale; the command path uses 0-100.
        # Normalize feedback to 0-100 so the slider matches what we send.
        v = if off_like
              0
            elsif attrs['brightness']
              ((attrs['brightness'].to_f / 255.0) * 100).round
            else
              attrs['brightness_pct']
            end
        client.send_update(entity_id, 'brightness_pct', v) unless v.nil?
      else
        v = attrs[k]
        v = 0 if v.nil? && off_like && LEVEL_KEYS.include?(k)
        client.send_update(entity_id, k, v) unless v.nil?
      end
    end

    # Safety net: even if a profile's state_filter didn't explicitly request a
    # level key, make sure dimmer tiles collapse on OFF. Harmless if unbound.
    if off_like && entity_id.start_with?('light.')
      client.send_update(entity_id, 'brightness', 0)     unless fkeys.include?('brightness')
      client.send_update(entity_id, 'brightness_pct', 0) unless fkeys.include?('brightness_pct')
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

  # No periodic discovery. New inventory is requested once when Savant opens
  # a fresh profile TCP session. Manual RefreshEntityCatalog remains available.
  log(:info, :server_started, port,
      { bind: bind, ha: address, log_level: LOG_LEVEL,
        catalog_discovery: 'on_savant_connect_or_manual', catalog_map_format: 'raw_entity_id' })
end
