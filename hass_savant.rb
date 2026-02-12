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
      parse_state(e)
    end
  end
end

module HassRequests
  def fan_on(entity_id, speed)
    send_data(type: :call_service, domain: :fan, service: :turn_on, service_data: { speed: speed }, target: { entity_id: entity_id })
  end
  def fan_off(entity_id, _speed = nil)
    send_data(type: :call_service, domain: :fan, service: :turn_off, target: { entity_id: entity_id })
  end
  def fan_set(entity_id, speed)
    speed.to_i.zero? ? fan_off(entity_id) : fan_on(entity_id, speed)
  end
  def switch_on(entity_id)
    send_data(type: :call_service, domain: :light, service: :turn_on, target: { entity_id: entity_id })
  end
  def switch_off(entity_id)
    send_data(type: :call_service, domain: :light, service: :turn_off, target: { entity_id: entity_id })
  end
  def dimmer_set(entity_id, level)
    level.to_i.zero? ? switch_off(entity_id) : send_data(type: :call_service, domain: :light, service: :turn_on, service_data: { brightness_pct: level }, target: { entity_id: entity_id })
  end
  def shade_set(entity_id, level)
    send_data(type: :call_service, domain: :cover, service: :set_cover_position, service_data: { position: level }, target: { entity_id: entity_id })
  end
  def socket_on(entity_id)
    send_data(type: :call_service, domain: :switch, service: :turn_on, target: { entity_id: entity_id })
  end
  def socket_off(entity_id)
    send_data(type: :call_service, domain: :switch, service: :turn_off, target: { entity_id: entity_id })
  end
end

class Hass
  include HassMessageParsingMethods
  include HassRequests

  POSTFIX = "\n"
  STATE_FILE = '/data/savant_hass_proxy_state.json'
  SAVANT_HELLO_INTERVAL = 10

  def initialize(hass_address, token, client)
    @address, @token, @client = hass_address, token, client
    @shutdown = false
    @ha_authed = false
    @id = 0
    @ws_queue = []
    @filter = ['all']
    
    @persisted = load_state
    apply_persisted_defaults

    ensure_em_running
    start_savant_io
    connect_websocket
  end

  def shutdown!; return if @shutdown; @shutdown = true; @hass_ws&.close; @client&.close rescue nil; end
  def shutdown?; @shutdown; end

  private

  def load_state; JSON.parse(File.read(STATE_FILE)) rescue { 'filter' => nil, 'entities' => [] }; end
  def save_state; File.write(STATE_FILE, @persisted.to_json) rescue nil; end

  def apply_persisted_defaults
    if (@filter.nil? || @filter == ['all']) && @persisted['filter'].is_a?(Array)
      @filter = @persisted['filter']
    end
  end

  def start_savant_io
    send_to_savant('hello,proxy=ha_savant,proto=1')
    listen_to_savant
    start_savant_heartbeat
  end

  def listen_to_savant
    Thread.new do
      begin
        while !@shutdown && (line = @client&.gets)
          from_savant(line.chomp)
        end
      rescue IOError, SystemCallError
        # Manejo silencioso de desconexión
      ensure
        shutdown!
      end
    end
  end

  def start_savant_heartbeat
    EM.add_periodic_timer(SAVANT_HELLO_INTERVAL) do
      send_to_savant('hello,proxy=ha_savant,proto=1') unless @shutdown
    end
  end

  def send_to_savant(msg)
    return if @shutdown || @client&.closed?
    @client.puts("#{msg}#{POSTFIX}")
  rescue
    shutdown!
  end

  def ensure_em_running
    Thread.new { EM.run } unless EM.reactor_running?
    sleep 0.1 until EM.reactor_running?
  end

  def connect_websocket
    EM.schedule do
      @hass_ws = Faye::WebSocket::Client.new(@address)
      @hass_ws.on(:message) { |e| handle_message(e.data) }
      @hass_ws.on(:close) { shutdown! }
      @hass_ws.on(:open) { p [:ws_open] }
    end
  end

  def from_savant(req)
    cmd, *params = req.split(',')
    case cmd
    when 'subscribe_events' then send_json(type: 'subscribe_events')
    when 'subscribe_entity' then send_json(type: 'subscribe_entities', entity_ids: params)
    when 'state_filter' then @filter = params; save_state
    else
      send(cmd, *params) if respond_to?(cmd)
    end
  end

  def handle_message(data)
    msg = JSON.parse(data)
    case msg['type']
    when 'auth_required' then send_json(type: 'auth', access_token: @token)
    when 'auth_ok' 
      @ha_authed = true
      send_to_savant('ready,ha=ok')
      # Restaurar suscripciones si existen
      ents = @persisted['entities'] || []
      send_json(type: 'subscribe_entities', entity_ids: ents) unless ents.empty?
    when 'event' then parse_event(msg['event'])
    when 'result' then parse_result(msg)
    end
  end

  def send_json(hash)
    @id += 1
    hash['id'] = @id unless hash['type'] == 'auth'
    EM.schedule { @hass_ws&.send(hash.to_json) }
  end

  def send_data(**data); send_json(data); end
end

# TCP Server Corregido
Thread.abort_on_exception = true
def start_tcp_server(hass_address, token, port = 8080)
  server = TCPServer.new(port)
  server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
  puts "Proxy iniciado en puerto #{port}"
  
  @active_instance = nil

  loop do
    client = server.accept
    client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    
    # Matar instancia anterior limpiamente antes de aceptar la nueva
    if @active_instance
      @active_instance.shutdown!
      sleep 0.1
    end
    
    @active_instance = Hass.new(hass_address, token, client)
  end
end

start_tcp_server(WS_URL, WS_TOKEN)
