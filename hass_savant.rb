#!/usr/bin/env ruby
# frozen_string_literal: true

require "socket"
require "json"
require "thread"

# =========================
# CONFIG
# =========================
TCP_PORT = 8080

# Home Assistant WS (local)
HA_WS_URL = "ws://127.0.0.1:8123/api/websocket"
HA_TOKEN  = "PEGAR_TOKEN_AQUI"

# Heartbeat a Savant (para que no marque Not Connected)
HEARTBEAT_INTERVAL_S = 2

# =========================
# HELPERS
# =========================
def log(level, *args)
  puts([Time.now.strftime("%H:%M:%S"), level, *args].inspect)
end

def safe_write(sock, data)
  sock.write(data)
rescue => e
  raise e
end

# =========================
# CLIENT MANAGER
# =========================
class ClientManager
  def initialize
    @clients = {} # sock => {mutex:, alive:}
    @lock = Mutex.new
  end

  def add(sock)
    @lock.synchronize do
      @clients[sock] = { mutex: Mutex.new, alive: true }
    end
  end

  def remove(sock)
    @lock.synchronize do
      @clients.delete(sock)
    end
  end

  def each_client
    snapshot = nil
    @lock.synchronize { snapshot = @clients.keys.dup }
    snapshot.each { |s| yield s }
  end

  def write(sock, msg)
    entry = nil
    @lock.synchronize { entry = @clients[sock] }
    return unless entry

    entry[:mutex].synchronize do
      safe_write(sock, msg)
    end
  end

  def broadcast(msg)
    each_client do |sock|
      begin
        write(sock, msg)
      rescue => e
        # Cliente muerto: lo sacamos sin tumbar a los otros
        begin sock.close rescue nil end
        remove(sock)
        log(:warn, :client_removed_on_write_error, e.class.to_s, e.message)
      end
    end
  end

  private

  def safe_write(sock, data)
    sock.write(data)
  end
end

# =========================
# HA CORE (WS)
# =========================
class HassCore
  def initialize(client_manager)
    @clients = client_manager
    @ws_mutex = Mutex.new
    @ws = nil
    @ws_connected = false
    @stop = false

    @cache_lock = Mutex.new
    @cache = {} # entity_id => {state:, attributes:}
  end

  def stop!
    @stop = true
  end

  def ha_ready?
    @ws_connected
  end

  def start
    start_ha_thread
  end

  def handle_savant_line(line)
    line = line.to_s.strip
    return if line.empty?

    # Commands from Savant
    # Examples:
    # state_filter,brightness,state,cover,lock,current_position,switch
    # subscribe_entity,switch.bano_principal_1,switch.bano_secundario_1,
    # socket_on,switch.x
    # socket_off,switch.x
    # dimmer_set,light.x,50
    # shade_set,cover.x,80
    # lock_lock,lock.x
    # unlock_lock,lock.x

    parts = line.split(",")
    cmd = parts.shift

    case cmd
    when "state_filter"
      # Savant expects ack
      return "state_filter===ok\n"
    when "subscribe_entity"
      return "subscribe_entity===ok\n"
    when "subscribe_events"
      return "subscribe_events===ok\n"
    when "socket_on"
      entity = parts[0]
      ha_call_service(domain: entity.split(".")[0], service: "turn_on", entity_id: entity)
      return "ok\n"
    when "socket_off"
      entity = parts[0]
      ha_call_service(domain: entity.split(".")[0], service: "turn_off", entity_id: entity)
      return "ok\n"
    when "dimmer_set"
      entity = parts[0]
      level  = (parts[1] || "0").to_i
      # HA uses brightness 0-255
      brightness = [[(level * 255.0 / 100.0).round, 0].max, 255].min
      ha_call_service(domain: "light", service: "turn_on", entity_id: entity, data: { "brightness" => brightness })
      return "ok\n"
    when "shade_set"
      entity = parts[0]
      level  = (parts[1] || "0").to_i
      ha_call_service(domain: "cover", service: "set_cover_position", entity_id: entity, data: { "position" => level })
      return "ok\n"
    when "lock_lock"
      entity = parts[0]
      ha_call_service(domain: "lock", service: "lock", entity_id: entity)
      return "ok\n"
    when "unlock_lock"
      entity = parts[0]
      ha_call_service(domain: "lock", service: "unlock", entity_id: entity)
      return "ok\n"
    when "close_garage_door"
      entity = parts[0]
      ha_call_service(domain: "cover", service: "close_cover", entity_id: entity)
      return "ok\n"
    when "open_garage_door"
      entity = parts[0]
      ha_call_service(domain: "cover", service: "open_cover", entity_id: entity)
      return "ok\n"
    when "toggle_garage_door"
      entity = parts[0]
      ha_call_service(domain: "cover", service: "toggle", entity_id: entity)
      return "ok\n"
    else
      return "unhandled===#{line}\n"
    end
  rescue => e
    log(:error, :handle_savant_line_error, e.class.to_s, e.message)
    return "error===#{e.class}:#{e.message}\n"
  end

  private

  # --- HA WS implementation without external gems:
  # This is a minimalistic WS client approach using TCPSocket is non-trivial.
  # In your project you likely already use a websocket gem.
  #
  # ✅ IMPORTANT: Keep using YOUR current HA WS code.
  # The main fix you needed is multi-client TCP & no global socket closing.
  #
  # Below we keep placeholders for your existing websocket logic.
  def start_ha_thread
    Thread.new do
      loop do
        break if @stop
        begin
          connect_ha
          # keep-alive loop placeholder
          loop do
            break if @stop
            # Here: read HA events, update cache, broadcast to Savant
            sleep 1
          end
        rescue => e
          @ws_connected = false
          log(:warn, :ws_disconnected, e.class.to_s, e.message)
          sleep 1
        end
      end
    end
  end

  def connect_ha
    # Replace with your working HA websocket code.
    # When connected:
    @ws_connected = true
    log(:info, :ha_ready)
    # And ideally broadcast hello:
    @clients.broadcast("ready===ok\n")
  end

  def ha_call_service(domain:, service:, entity_id:, data: {})
    # Replace with your existing HA WS send logic.
    # This stub only logs.
    log(:info, :ha_service_call, domain, service, entity_id, data)
  end
end

# =========================
# TCP SERVER (SAVANT)
# =========================
clients = ClientManager.new
ha = HassCore.new(clients)
ha.start

server = TCPServer.new("0.0.0.0", TCP_PORT)
log(:info, :server_started, TCP_PORT)

# Heartbeat thread
Thread.new do
  loop do
    sleep HEARTBEAT_INTERVAL_S
    clients.broadcast("heartbeat===1\n")
  end
end

loop do
  sock = server.accept
  peer = sock.peeraddr rescue ["?", "?", "?", "?"]
  log(:info, :client_connected, peer)

  clients.add(sock)

  # Send immediate ready to new clients (helps Savant keep Connected)
  begin
    clients.write(sock, "ready===ok\n")
  rescue => e
    log(:warn, :initial_ready_failed, e.class.to_s, e.message)
    begin sock.close rescue nil end
    clients.remove(sock)
    next
  end

  # Reader thread per client
  Thread.new(sock) do |client|
    begin
      buffer = +""
      loop do
        data = client.readpartial(1024)
        buffer << data
        while (idx = buffer.index("\n"))
          line = buffer.slice!(0..idx)
          response = ha.handle_savant_line(line)
          # if Savant expects something, answer
          if response && !response.empty?
            clients.write(client, response)
          end
        end
      end
    rescue EOFError
      log(:info, :client_disconnected)
    rescue => e
      log(:error, :savant_read_error, e.class.to_s, e.message)
    ensure
      begin client.close rescue nil end
      clients.remove(client)
    end
  end
end
