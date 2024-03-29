#!/usr/bin/ruby

require 'rubygems'
require 'eventmachine'
require 'json'
require './encrypt'


cfg_file = File.open('config.json')
config =  JSON.parse(cfg_file.read)
cfg_file.close

key = config['password']

$server = config['server']
$remote_port = config['server_port'].to_i
$port = config['local_port'].to_i

$encrypt_table, $decrypt_table = get_table(key)

def inet_ntoa(n)
    n.unpack("C*").join "."
end

module LocalServer
  class LocalConnector < EventMachine::Connection
    def initialize server
      @server = server
      super
    end

    def post_init
      addr_to_send = @server.addr_to_send.clone
      encrypt $encrypt_table, addr_to_send
      send_data addr_to_send

      for piece in @server.cached_pieces
        encrypt $encrypt_table, piece
        send_data piece
      end
      @server.cached_pieces = nil

      @server.stage = 5
    end

    def receive_data data
      encrypt $decrypt_table, data
      @server.send_data data
    end

    def unbind
      @server.close_connection_after_writing
    end
  end

  attr_accessor :remote_addr,
                :remote_port,
                :stage,
                :addr_to_send,
                :cached_pieces

  def post_init
    @stage = 0
    @header_length = 0
    @remote = 0
    @cached_pieces = []
    @remote_addr = nil
    @remote_port = nil
    @connector = nil
    @addr_to_send = ""
  end




  def receive_data data
    if @stage == 5
      encrypt $encrypt_table, data
      @connector.send_data data
      return
    end
    if @stage == 0
      send_data "\x05\x00"
      @stage = 1
      return
    end
    if @stage == 1
      begin
        addr_len = 0
        cmd = data[1]
        addrtype = data[3]
        if cmd != "\x01"
          warn "unsupported cmd: " + cmd.unpack('c')[0].to_s
          close_connection
          return
        end
        if addrtype == "\x03"
          addr_len = data[4].unpack('c')[0]
        elsif addrtype != "\x01"
          warn "unsupported addrtype: " + addrtype.unpack('c')[0].to_s
          close_connection
          return
        end
        @addr_to_send = data[3]
        if addrtype == "\x01"
          @addr_to_send += data[4..9]
          @remote_addr = inet_ntoa data[4..7]
          @remote_port = data[8, 2].unpack('s>')[0]
          @header_length = 10
        else
          @remote_addr = data[5, addr_len]
          @addr_to_send += data[4..5 + addr_len + 2]
          @remote_port = data[5 + addr_len, 2].unpack('s>')[0]
          @header_length = 5 + addr_len + 2
        end
        send_data "\x05\x00\x00\x01\x00\x00\x00\x00" + [@remote_port].pack('s>')
        @stage = 4
        if data.size > @header_length
          @cached_pieces.push data[@header_length, data.size]
        end

        @connector = EventMachine.connect $server, $remote_port, LocalConnector, self
      rescue Exception => e
        warn e
        if @connector != nil
          @connector.close_connection
        end
        close_connection
      end
    elsif @stage == 4
      @cached_pieces.push data
    end

  end

  def unbind
    if @connector != nil
      @connector.close_connection_after_writing
    end

  end
end

EventMachine::run {
  EventMachine::start_server "127.0.0.1", $port, LocalServer
}
