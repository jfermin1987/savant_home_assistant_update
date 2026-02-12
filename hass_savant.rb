WS_TOKEN = ENV['SUPERVISOR_TOKEN']
WS_URL = "ws://supervisor/core/api/websocket"
TCP_PORT = 8080
require 'socket'
require 'json'
require 'faye/websocket'
require 'eventmachine'

# Módulos de parsing y peticiones (Lógica preservada intacta)
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
    else [:unknown, js_data['event_type']]
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
      else update?(key, i, e)
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
  def fan_set(entity_id, speed)
    service = speed.to_i.zero? ? :turn_off : :turn_on
    data = speed.to_i.zero? ? {} : { speed: speed }
    send_data(type: :call_service, domain: :fan, service: service, service_data: data, target: { entity_id: entity_id })
  end
  def switch_on(e); send_data(type: :call_service, domain: :light, service: :turn_on, target: { entity_id: e }); end
  def switch_off(e); send_data(type: :call_service, domain: :light, service: :turn_off, target: { entity_id: e }); end
  def dimmer_set(e, v); v.to_i.zero? ? switch_off(e) : send_data(type: :call_service, domain: :light, service: :turn_on, service_data: { brightness_pct: v }, target: { entity_id: e }); end
  def shade_set(e, v); send_data(type: :call_service, domain: :cover, service: :set_cover_position, service_data: { position: v }, target: { entity_id: e }); end
  def lock_lock(e); send_data(type: :call_service, domain: :lock, service: :lock, target: { entity_id: e }); end
  def unlock_lock(e); send_data(type: :call_service, domain: :lock, service: :unlock, target: { entity_id: e }); end
  def socket_on(e); send_data(type: :call_service, domain: :switch, service: :turn_on, target: { entity_id: e }); end
  def socket_off(e); send_data(type: :call_service, domain: :switch, service: :turn_off, target: { entity_id: e }); end
  def button_press(e); send_data(type: :call_service, domain: :button, service: :press, target: { entity_id: e }); end
  def open_garage_door(e); send_data(type: :call_service, domain: :cover, service: :open_cover, target: { entity_id: e }); end
  def close_garage_door(e); send_data(type: :call_service, domain: :cover, service: :close_cover, target: { entity_id: e }); end
end

class Hass
  include HassMessageParsingMethods
  include HassRequests

  POSTFIX = "\n"
  STATE_FILE = '/data/savant_hass_proxy_state.json'

  def initialize(hass_address, token, client)
    @address, @token, @client = hass_address, token, client
    @shutdown = false
    @ha_authed = false
    @id = 0
    @ws_queue = []
    @filter = ['all']
    
    ensure_em_running
    start_savant_io
    connect_websocket
  end

  def shutdown!; return if @shutdown; @shutdown = true; @hass_ws&.close; @client&.close rescue nil; end
  def shutdown?; @shutdown; end

  private

  def start_savant_io
    send_to_savant('hello,proxy=ha_savant,proto=1')
    listen_to_savant
  end

  def listen_to_savant
    Thread.new do
      while !@shutdown && (line = @client.gets)
        from_savant(line.chomp)
      end
      shutdown!
    end
  end

  def send_to_savant(msg)
    return if @shutdown || @client.closed?
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
    end
  end

  def from_savant(req)
    cmd, *params = req.split(',')
    case cmd
    when 'subscribe_events' then send_json(type: 'subscribe_events')
    when 'subscribe_entity' then send_json(type: 'subscribe_entities', entity_ids: params)
    when 'state_filter' then @filter = params
    else send(cmd, *params) if respond_to?(cmd)
    end
  end

  def handle_message(data)
    msg = JSON.parse(data)
    case msg['type']
    when 'auth_required' then send_json(type: 'auth', access_token: @token)
    when 'auth_ok' 
      @ha_authed = true
      send_to_savant('ready,ha=ok')
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

# TCP Server Corregido para evitar colisiones
Thread.abort_on_exception = true
def start_tcp_server(hass_address, token, port = 8080)
  server = TCPServer.new(port)
  server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
  puts "Server started on port #{port}"
  
  @active_instance = nil

  loop do
    client = server.accept
    client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    
    # Cerramos la instancia previa antes de aceptar la nueva para evitar el parpadeo
    @active_instance.shutdown! if @active_instance
    @active_instance = Hass.new(hass_address, token, client)
  end
end

start_tcp_server(WS_URL, WS_TOKEN)
