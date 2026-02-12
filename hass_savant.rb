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
    case js_data['event_type']
    when 'state_changed' then parse_state(new_data(js_data))
    when 'call_service' then parse_service(new_data(js_data))
    end
  end

  def parse_state(message)
    eid = message['entity_id']
    update?("#{eid}_state", 'state', message['state']) if eid
    atr = message['attributes']
    if atr.is_a?(Hash)
      atr.each { |k, v| update?("#{eid}_#{k}", k, v) if included_with_filter?(k) }
    end
  end

  def update?(key, primary_key, value)
    return unless value && included_with_filter?(primary_key)
    send_to_savant("#{key}===#{value}")
  end

  def included_with_filter?(pk)
    @filter.empty? || @filter.include?('all') || @filter.include?(pk)
  end

  def parse_result(js_data)
    res = js_data['result']
    return unless res
    res.is_a?(Array) ? res.each { |e| parse_state(e) } : parse_state(res)
  end
end

module HassRequests
  def switch_on(e); send_data(type: :call_service, domain: :light, service: :turn_on, target: { entity_id: e }); end
  def switch_off(e); send_data(type: :call_service, domain: :light, service: :turn_off, target: { entity_id: e }); end
  def socket_on(e); send_data(type: :call_service, domain: :switch, service: :turn_on, target: { entity_id: e }); end
  def socket_off(e); send_data(type: :call_service, domain: :switch, service: :turn_off, target: { entity_id: e }); end
  def dimmer_set(e, v); v.to_i.zero? ? switch_off(e) : send_data(type: :call_service, domain: :light, service: :turn_on, service_data: { brightness_pct: v }, target: { entity_id: e }); end
end

class Hass
  include HassMessageParsingMethods
  include HassRequests

  def initialize(hass_address, token, client)
    @address, @token, @client = hass_address, token, client
    @shutdown = false
    @ha_authed = false
    @id = 0
    @filter = ['all']
    
    ensure_em_running
    connect_websocket
    start_savant_io
  end

  def shutdown!
    return if @shutdown
    @shutdown = true
    EM.next_tick { @hass_ws&.close }
    @client&.close rescue nil
  end

  private

  def start_savant_io
    send_to_savant('hello,proxy=ha_savant,proto=1')
    Thread.new do
      begin
        while !@shutdown && (line = @client&.gets)
          msg = line.chomp
          from_savant(msg) unless msg.empty?
        end
      rescue
      ensure
        shutdown!
      end
    end
  end

  def send_to_savant(msg)
    return if @shutdown || @client&.closed?
    @client.puts("#{msg}\n")
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
    # No procesar comandos de Savant si el WebSocket no está listo
    return unless @ha_authed 
    
    cmd, *params = req.split(',')
    case cmd
    when 'subscribe_events' then send_json(type: 'subscribe_events')
    when 'subscribe_entity' then send_json(type: 'subscribe_entities', entity_ids: params)
    when 'state_filter' then @filter = params
    else send(cmd, *params) if respond_to?(cmd.to_sym)
    end
  end

  def handle_message(data)
    msg = JSON.parse(data)
    case msg['type']
    when 'auth_required' then send_json(type: 'auth', access_token: @token)
    when 'auth_ok' 
      @ha_authed = true
      send_to_savant('ready,ha=ok')
      puts "HA Autenticado y Ready enviado a Savant"
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

# Servidor TCP Robusto
Thread.abort_on_exception = true
@server_mutex = Mutex.new

def start_tcp_server(hass_address, token, port = 8080)
  server = TCPServer.new(port)
  server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
  puts "Proxy iniciado en puerto #{port}. Esperando a Savant..."
  
  @active_instance = nil

  loop do
    client = server.accept
    client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    
    @server_mutex.synchronize do
      if @active_instance
        puts "Cerrando conexión antigua..."
        @active_instance.shutdown!
        sleep 0.5 # Tiempo para que el puerto se libere realmente
      end
      puts "Nueva conexión desde Savant aceptada."
      @active_instance = Hass.new(hass_address, token, client)
    end
  end
end

start_tcp_server(WS_URL, WS_TOKEN)
