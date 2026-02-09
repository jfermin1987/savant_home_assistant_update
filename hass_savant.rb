WS_TOKEN = ENV['SUPERVISOR_TOKEN']
WS_URL = "ws://supervisor/core/api/websocket"
TCP_PORT = 8080
require 'socket'
require 'json'
require 'faye/websocket'
require 'eventmachine'

module HassMessageParsingMethods
  def parse_event(js_data)
    return entities_changed(js_data['c']) if js_data.keys == ['c']
    return entities_changed(js_data['a']) if js_data.keys == ['a']
    case js_data['event_type']
    when 'state_changed' then parse_state(js_data['data']['new_state'] || js_data['data'])
    end
  end

  def entities_changed(entities)
    entities.each do |entity, state|
      state = state['+'] if state.key?('+')
      update?("#{entity}_state", 'state', state['s']) if state['s']
      update_with_hash(entity, state['a']) if state['a']
    end
  end

  def parse_state(message)
    return unless message
    eid = message['entity_id']
    update?("#{eid}_state", 'state', message['state']) if eid
    update_with_hash(eid, message['attributes']) if message['attributes']
  end

  def update?(key, primary_key, value)
    return unless value && (@filter.include?('all') || @filter.include?(primary_key))
    @persisted['last_states'] ||= {}
    @persisted['last_states'][key] = value
    save_state
    send_to_savant("#{key}===#{value}")
  end

  def update_with_hash(parent_key, msg_hash)
    msg_hash.each { |k, v| update?("#{parent_key}_#{k}", k, v) }
  end

  def parse_result(js_data)
    res = js_data['result']
    return unless res
    res.is_a?(Array) ? res.each { |e| parse_state(e) } : parse_state(res)
  end
end

class Hass
  include HassMessageParsingMethods
  STATE_FILE = '/data/savant_hass_proxy_state.json'

  def initialize(client)
    @client = client
    @id = 0
    @ha_authed = false
    @filter = ['all']
    @persisted = load_state
    @filter = @persisted['filter'] if @persisted['filter']
    
    start_savant_io
    connect_websocket
  end

  def load_state
    JSON.parse(File.read(STATE_FILE)) rescue { 'filter' => ['all'], 'entities' => [], 'last_states' => {} }
  end

  def save_state
    File.write(STATE_FILE, @persisted.to_json) rescue nil
  end

  def start_savant_io
    send_to_savant("ready,proxy=ha_savant")
    # Enviar estados guardados de inmediato para evitar estados vacíos en Savant
    @persisted['last_states']&.each { |k, v| send_to_savant("#{k}===#{v}") }
    
    Thread.new do
      while (req = @client.gets&.chomp)
        cmd, *params = req.split(',')
        case cmd
        when 'subscribe_entity'
          @persisted['entities'] = (@persisted['entities'] + params).uniq
          save_state
          send_json(type: 'subscribe_entities', entity_ids: params)
        when 'state_filter'
          @filter = params
          @persisted['filter'] = params
          save_state
        when 'lock_lock'    then send_json(type: 'call_service', domain: 'lock', service: 'lock', target: {entity_id: params[0]})
        when 'unlock_lock'  then send_json(type: 'call_service', domain: 'lock', service: 'unlock', target: {entity_id: params[0]})
        when 'shade_set'    then send_json(type: 'call_service', domain: 'cover', service: 'set_cover_position', service_data: {position: params[1].to_i}, target: {entity_id: params[0]})
        when 'switch_on'    then send_json(type: 'call_service', domain: 'light', service: 'turn_on', target: {entity_id: params[0]})
        when 'switch_off'   then send_json(type: 'call_service', domain: 'light', service: 'turn_off', target: {entity_id: params[0]})
        end
      end
    end
  end

  def connect_websocket
    EM.run do
      @ws = Faye::WebSocket::Client.new(WS_URL)
      @ws.on(:message) { |e| handle_ha_msg(JSON.parse(e.data)) }
      @ws.on(:close) { EM.add_timer(5) { connect_websocket } }
    end
  end

  def handle_ha_msg(msg)
    case msg['type']
    when 'auth_required' then @ws.send({type: 'auth', access_token: WS_TOKEN}.to_json)
    when 'auth_ok'
      @ha_authed = true
      send_json(type: 'subscribe_entities', entity_ids: @persisted['entities']) unless @persisted['entities'].empty?
      send_json(type: 'get_states')
    when 'event' then parse_event(msg['event'])
    when 'result' then parse_result(msg)
    end
  end

  def send_json(hash)
    hash['id'] = (@id += 1)
    @ws.send(hash.to_json) if @ha_authed
  end

  def send_to_savant(msg); @client.puts(msg); end
end

server = TCPServer.new(8080)
loop { Thread.new(server.accept) { |c| Hass.new(c) } }
