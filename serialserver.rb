#!/usr/bin/env ruby
# serialserver.rb  
require 'rubygems'
require 'timeout'
require 'logger'
require 'pp'
require "socket"  
require "serialport"
include Socket::Constants

#serialserver.rb config
$sshost='127.0.0.1' 
$ssport=9761

$tty='/dev/ttyUSB0'

$log = Logger.new(STDOUT)
$log.level = Logger::INFO
$log.datetime_format = "%Y-%m-%d %H:%M:%S"
$log.info('Starting...')


$log.info("Starting TCP server on port #{$sshost} #{$ssport}")
server = TCPServer.new($sshost, $ssport)

while true
   catch :socketerror do
      rclients= []
      wclients= []
      eclients= []

      $log.info("Opening serialport on device #{$tty}")
      sp = SerialPort.new $tty,19200
      sp.read_timeout = 100
      sp.flow_control = SerialPort::NONE

      begin
         rclients << server.accept_nonblock
      rescue Errno::EAGAIN, Errno::ECONNABORTED, Errno::EPROTO, Errno::EINTR
         IO.select([server])
         retry
      end
      $log.info("TCP connecton on port #{$ssport} is accepted")  

      while true
         readable, writeable = IO.select(rclients,wclients,eclients,0.1)
         if readable
            readable.each do |s|
               command = ''
               begin
                  command,sa = s.read_nonblock(1024)
               rescue Errno::EAGAIN
                  IO.select([s])
               rescue
                  $log.error("TCP connecton on port #{$ssport} is gone")  
                  s.close 
                  sp.close
                  throw :socketerror
               end
               if !command.empty?
                  retval = sp.write(command)
                  $log.info "Request:  #{command.unpack('H*').join.upcase}"
                 #sleep(0.1)
               end
            end
         end
         r = sp.read
         if !r.empty?
            $log.info("Response: #{r.unpack('H*').join.upcase}")
            rclients[0].write r
         end
         Thread.pass
      end
   end
end  
