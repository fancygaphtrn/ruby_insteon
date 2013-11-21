require 'timeout'
require 'thread'
require 'logger'
require 'socket'  
require 'pp'
require 'cgi'
include Socket::Constants

class IQueue < Queue  
  def contents  
    @mutex.synchronize {
		return @que
	}  
  end  
  def empty?  
    @mutex.synchronize {
		return @que.empty?
	}  
  end  
  def getDevice(device,non_block=false)  
	@mutex.synchronize {
		tqueue = []
		mqueue = []
        @que.each {|x|
            if x['Path'][0..9] == "0262#{device}"
				mqueue << x
             else
                tqueue << x
            end
        }
		@que = tqueue
		return mqueue
	}
  end  
  def getController(controller,non_block=false)  
	@mutex.synchronize {
		tqueue = []
		mqueue = []
        @que.each {|x|
            if x['Time'] <= Time.now and x['Controller'] == controller
				mqueue << x
             else
                tqueue << x
            end
        }
		if mqueue.empty?
			raise ThreadError, "queue empty" if non_block
			@waiting.push Thread.current
			r = @mutex.sleep(1)
			@waiting.delete Thread.current
			mqueue = []
		else
			@que = tqueue
			return mqueue
		end
	}
  end  
end  

class ControllerPLM
	attr_accessor :writesleeptime, :maxhops, :heartbeat, :long, :lat, :timezone, :webserver
	def initialize(params = {})
		options = {
			:writesleeptime => 0.3,
			:maxhops 		=> 1,
			:heartbeat		=> 600,
			:long 			=> "36.76",
			:lat 			=> "-80.73",
			:timezone 		=> 'America/New_York',
			:webserver 		=> {'name'=>'Web Server','host'=>'0.0.0.0','port'=>9091, 'username'=>'', 'password' => ''}
		}.merge(params)

		@writesleeptime = options[:writesleeptime] # seconds between consecutive PLM message writes
		@maxhops 		= options[:maxhops] # max hops for sending 0262 messages 0262 to PLM  must be between 1 and 3
		@heartbeat 		= options[:heartbeat] # seconds between heartbeat messages to check the connection is still alive.
		#Create the location for Sunrise and Sunset
		@long 			= options[:long]
		@lat 			= options[:lat]
		@timezone 		= options[:timezone]
		@webserver 		= options[:webserver]

		@recvqueue = IQueue.new
        @sendqueue = IQueue.new
        @starttime = Time.now
        @threads = []
		@controllers = {}

		query = "SELECT * from jos_insteondevices WHERE icontroller = 1 and published = 1 order by ordering"
		$log.debug(query)
		res = $mysql.query(query)
		if res.num_rows() != 0
			res.each_hash do |row|
				@controllers[row['device']] = {'name'=>row['friendlyname'],'host'=>row['ipaddress'],'port'=>row['port'].to_i, 'username'=>row['username'], 'password' =>row['password'],'buffer'=>'','socket'=> nil} 
			end
		else
			puts "No controllers defined in database";
			exit(1)
		end

		
        @devices = {}
        query = "SELECT *, a.description as description, b.description as adescription from jos_insteondevices as a "
        query += "LEFT JOIN jos_insteonareas as b ON a.insteonareas_id = b.id "
        query += "WHERE a.published = 1 "
        query += "ORDER BY b.description, a.friendlyname "

        $log.debug(query)
        res = $mysql.query(query)
        if res.num_rows() > 0
            res.each_hash() {|d|
				if d['icontroller'] != '1'
 					@devices[d['device']] = {'controller'=>d['controller'],'adescription'=>d['adescription'],'friendlyname'=>d['friendlyname'],'description'=>d['description'],'category'=>d['type'][0..1],'subcategory'=>d['type'][2..3],'type'=>d['type'],'display'=>d['display'],'engine'=>d['engine'],'state'=>d['state'],'brightness'=>d['brightness'],'hopsaverage'=>d['hopsaverage'],'hopscount'=>d['hopscount'],'lastupdate'=>Time.now,'hopsmax'=>'0'}
                end
            }
        end
   end

   def start
      @controllers.each_key {|i|
		#opensocket(i)
        @threads << Thread.new {
            Thread.current["name"] = "Write #{i}"
			pingtime = Time.now
            loop do
			    Thread.current["time"] = Time.now
                messages = getmessages(i)
                messages.each {|m|
					WritePLM(m['Controller'],m['Path'],m['ErrorDesc'])
                    pingtime = Time.now
                    sleep(@writesleeptime)# don't go to fast or you will over run the PLM
                }
                if Time.now > pingtime + @heartbeat
                    SendGetIMinfo(i)
                    pingtime = Time.now
                end
            end     
        }
        @threads << Thread.new {
            Thread.current["name"] = "Read  #{i}"
            loop do
				Thread.current["time"] = Time.now
                check_controllers(i)
			end     
        }
      }
      @threads << Thread.new {
         Thread.current["name"] = @webserver['name']
         server = TCPServer.new(@webserver['host'], @webserver['port'])
         logStr =  "Web server started on: #{@webserver['host']} (#{@webserver['port']})"
         $log.info(logStr)
         loop do
			Thread.current["time"] = Time.now
            session = server.accept
			lines = []
			while line = session.gets and line !~ /^\s*$/
				lines << line.chomp
			end
            request = lines.join

			trequest=request.scan(/GET \/(.*)\?(.*) HTTP.*/)
			if trequest.empty?
				request_file = ''
				request_command = ''
				request_device = ''
				request_callback = ''
			else
				request_file = trequest[0][0]
				query = CGI.parse(trequest[0][1])
				request_command = query['command'].join
				request_device = query['device'].join
				request_callback = query['callback'].join
			end
            @threads << Thread.start(session, request) do |session, request|
				Thread.current["name"] = "Web Server #{session.peeraddr[2]} #{session.peeraddr[1]}"
				Thread.current["time"] = Time.now

				#  GET /insteon?device=154AE3&command=0262154AE30F1300 HTTP/1.0
				logStr =  "Web request: #{session.peeraddr[2]} (#{session.peeraddr[3]}) #{request_command} #{request_device}"
				$log.debug(logStr)

				if request_file == 'insteon' and request_command[0..1] == '02' and !request_device.empty?
					$log.debug("Received insteon Web Server command #{@controllers[getcontroller(request_device)]['name']} #{request_command} ")

					ClearSendQueue(request_device)
					SendPLM(getcontroller(request_device),request_command,'Web Command')

					response = "HTTP/1.1 200/OK\r\nServer: Insteon\r\nContent-type: application/json\r\n\r\n"
					
					if !request_callback.empty?
						response += "#{request_callback}("
					end
					response += "[{status:'ok'}]"
					if !request_callback.empty?
						response += ");"
					end
				elsif request_file == 'insteon' and request_command == 'json'

					$log.debug("Received Insteon Web Server command #{request_command} ")

					response = "HTTP/1.1 200/OK\r\nServer: Insteon\r\nContent-type: application/json\r\n\r\n"
					
					if !request_callback.empty?
						response += "#{request_callback}("
					end
					response += "["
	
					@devices.each_pair{|c,val|
					if @devices[c]['display'] == "1"
							response += '{"device":"' + c + '",'
							val.each_pair {|key,value|
								if value.class == Time
								response += '"' + key + '":"' + value.strftime("%Y-%m-%d %I:%M:%S%P") + '",'
								elsif value.class == Fixnum
								response += '"' + key + '":"' + value.to_s + '",'
								elsif value.class == Float
								response += '"' + key + '":"' + value.to_s + '",'
								else
								response += '"' + key + '":"' + value + '",'
								end


							}
							response = response[0..response.length-2]
							response += "},"
						end
					}
					response = response[0..response.length-2]
					response += "]"
					if !request_callback.empty?
						response += ");"
					end

				elsif request_file == 'insteon' and request_command == 'status'

					$log.debug("Received Insteon Web Server command #{request_command} ")
					response = "HTTP/1.1 200/OK\r\nServer: Insteon\r\nContent-type: text/html\r\n\r\n"
					time = Time.now

					indent = "&nbsp;&nbsp;&nbsp;&nbsp;"
					timeformat = "%Y-%m-%d %I:%M:%S%P"
					
					response += "<html>"
					response += "<head>"
					response += '<style type="text/css">'
					response += "body {"
					response += "   font-family: Arial, Helvetica, sans-serif;"
					response += "   background: #fff;"
					response += "   color: #000000;"
					response += "   font-size: 14px;"
					response += "}"
					response += "table {"
					response += "   width: 100%;"
					response += "   background: #fff;"
					response += "   color: #000000;"
					response += "   font-size: 14px;"
					response += "}"
					response += "th {"
					response += "   font-weight: bold;"
					response += "   text-align: left;"
					response += "}"
					response += "pre {margin:0px;}"
					response += "</style>"
					response += "</head>"
					response += "<body>"


					response += "Current time: #{time.strftime(timeformat)}<br/>"

					date = Date.parse(time.to_s)
					calc = SolarEventCalculator.new(date, BigDecimal.new(@long), BigDecimal.new(@lat))  
					localSunrise = calc.compute_official_sunrise(@timezone) 
					localSunset = calc.compute_official_sunset(@timezone)  
					sr = Time.parse(localSunrise.to_s)
					ss = Time.parse(localSunset.to_s)

					response += "Sunrise time: #{sr.strftime(timeformat)}<br/>"
					response += "Setset time:  #{ss.strftime(timeformat)}<br/>"
					response += "Startup time: #{@starttime.strftime(timeformat)}<br/><br/>"
				
					uptime=time-@starttime
					secs=uptime.to_int
					mins  = secs / 60
					hours = mins / 60
					days  = hours / 24

					response += "Uptime: #{days} days, #{hours % 24} hours, #{mins % 60} minutes, #{secs % 60} seconds<br/><br/>"
				
					response += "<table><tr><td>Thread: #{Thread.main["name"]}</td><td>#{Thread.main.status}</td><td>#{Thread.main["time"].strftime(timeformat)}</td></tr>"
					@threads.each{|t|
						response += "<tr><td>Thread: #{t["name"]}</td><td>#{t.status}</td><td>#{t["time"].strftime(timeformat)}</td></tr>"
					}
					response += "</table><br/>"
					
					response += "@maxhops#{indent}#{@maxhops}<br/>"
					response += "@heartbeat#{indent}#{@heartbeat}<br/>"
					response += "@long#{indent}#{@long}<br/>"
					response += "@lat#{indent}#{@lat}<br/>"
					response += "@timezone#{indent}#{@timezone}<br/>"
					response += "@writesleeptime#{indent}#{@writesleeptime}<br/><br/>"
					
					response += "@webserver<br/><table><tr>"

					@webserver.each {|key,value|
							response += "<th>#{key}</th>"
					}
					response += "</tr>"

					response += "<tr>"
					@webserver.each {|key,value|
						response += "<td>#{value}</td>"
					}
					response += "</tr>"

					response += "</tr></table><br/>"

					response += "@controllers<br/><table>"
					@controllers.each_pair{|c,val|
						response += "<tr><th>Controller</th>"
						val.each_pair {|key,value|
							response += "<th>#{key}</th>"
						}
						break;
					}
					@controllers.each_pair{|c,val|
						response += "</tr><tr><td>#{c}</td>"
						val.each_pair {|key,value|
							if value.class == Time
								response += "<td>#{value.strftime(timeformat)}</td>"
							elsif value.class == TCPSocket
								response += "<td>TCP socket</td>"
							else
								response += "<td>#{value}</td>"
							end
						}
						response += "</tr>"
					}
					response += "</table><br/>"

					response += "@devices<br/><table>"
					@devices.each_pair{|c,val|
						response += "<tr><th>Device</th>"
						val.each_pair {|key,value|
							response += "<th>#{key}</th>"
						}
						break;
					}
					@devices.each_pair{|c,val|
						response += "</tr><tr><td>#{c}</td>"
						val.each_pair {|key,value|
							if value.class == Time
								response += "<td>#{value.strftime(timeformat)}</td>"
							else
								response += "<td>#{value}</td>"
							end
						}
						response += "</tr>"
					}
					response += "</table><br/>"

					response += "@recvqueue<br/><table>"
					@recvqueue.contents.each{|c|
						response += "<tr>"
						c.each_pair {|key,value|
							response += "<th>#{key}</th>"
						}
						break;
					}
					@recvqueue.contents.each{|c|
						response += "</tr><tr>"
						c.each_pair {|key,value|
							if value.class == Time
								response += "<td>#{value.strftime(timeformat)}</td>"
							else
								response += "<td>#{value}</td>"
							end
						}
					}
					response += "</tr></table><br/>"

					response += "@sendqueue<br/><table>"
					@sendqueue.contents.each{|c|
						response += "<tr>"
						c.each_pair {|key,value|
							response += "<th>#{key}</th>"
						}
						break;
					}
					@sendqueue.contents.each{|c|
						response += "</tr><tr>"
						c.each_pair {|key,value|
							if value.class == Time
								response += "<td>#{value.strftime(timeformat)}</td>"
							else
								response += "<td>#{value}</td>"
							end
						}
					}
					response += "</tr></table><br/>"
					response += "</body>"
					response += "</html>"

				elsif request_file == 'directv' and !request_command.empty?

					$log.debug("Received Directv Web Server command #{request} #{request_device} #{request_command} ")
					
					s = TCPSocket.new( device, 8080 )
					s.sync = true
					s.write "GET #{request_command} HTTP/1.0\r\n\r\n"
					while true
						partial_data = s.recv(1024)
						if partial_data.length == 0
							break
						end
						recv = "#{recv}#{partial_data}"
					end
					s.close
					
					response = "HTTP/1.1 200/OK\r\nServer: Insteon\r\nContent-type: text/plain\r\n\r\n#{recv}"
					session.print response
					session.close

				else
					$log.debug("Received Unknown Insteon Web Server request")
					response = "HTTP/1.1 404/Object Not Found\r\nServer Insteon\r\n\r\n"
					response += "404 - Resource cannot be found."
				end
				session.print response
				session.close
				@threads.delete(Thread.current)
            end
         end
      }
      return @threads
   end

   def opensocket(i)
        begin
            @controllers[i]['socket'] = TCPSocket.new( @controllers[i]['host'], @controllers[i]['port'] )
			@controllers[i]['socket'].sync = true
        rescue
            @controllers[i]['socket'] = nil
			$log.error("Socket Open for #{i} #{@controllers[i]['friendlyname']} #{@controllers[i]['host']} #{@controllers[i]['port']} error #{$!} #{$@[0]} Line: #{$.}")
            sleep(10)
            retry
        end
   end

   def closesocket(i)
		begin
            if @controllers[i]['socket'] != nil
				@controllers[i]['socket'].close
				@controllers[i]['socket'] = nil
			end
        rescue
            $log.error("Socket Close for #{i} #{@controllers[i]['friendlyname']} #{@controllers[i]['host']} #{@controllers[i]['port']} error #{$!} #{$@[0]} Line: #{$.}")
            sleep(10)
            retry
        end
   end

   def ClearSendQueue(device)
		mqueue = @sendqueue.getDevice(device)
		mqueue.each{|message|
            $log.info("Removing Queued command #{message['Path']} #{message['ErrorDesc']} #{message['Time']}")
		}
        return mqueue
   end
   
   def clearRecvQueue()
        @recvqueue.clear()
   end

   def getmessages(controller)
		mqueue = @sendqueue.getController(controller)
        return mqueue
   end

   def sendpush(message)
		@sendqueue << message
   end
   def sendpop(non_block=false)
        return @sendqueue.shift(non_block)
   end
   def recvpush(message)
        @recvqueue << message
   end
   def recvpop(non_block=false)
        return @recvqueue.shift(non_block)
   end

   def recvempty()
        return @recvqueue.empty?
   end
   
   def recv_controller(controller)
      begin
		if @controllers[controller]['socket'] == nil
			opensocket(controller)
		end
		recv = @controllers[controller]['socket'].recv( 1024 )
        if recv.length == 0
			$log.error("Socket #{controller} #{@controllers[controller]['friendlyname']} returned 0 bytes")
			raise
		end
		retval = recv.unpack('H*').join.upcase
		return retval
      rescue 
        $log.error("Socket read error for #{controller} #{@controllers[controller]['friendlyname']} #{@controllers[controller]['host']} #{@controllers[controller]['port']} #{$!} #{$@[0]} Line: #{$.}")
        closesocket(controller)
        sleep(1)
		opensocket(controller)
		retry
     end
   end

   def check_controllers(s)
      @controllers[s]['lastread'] = recv_controller(s)
      @controllers[s]['buffer'] += @controllers[s]['lastread']
      @controllers[s]['lastreadtime'] = Time.now
      @controllers[s]['buffer'] = queue_messages(s,@controllers[s]['name'],@controllers[s]['buffer'])
	  #if !@controllers[s]['buffer'].empty?
			#$log.error("Controller buffer roll #{@controllers[s]['buffer']}")
	  #end
   end

   def parse(buff, len)
		retval = ''
		match = 0
		if buff.length >= len
			retval = buff[0..len-1]
			blen = buff.length
			buff = buff[len..blen]
			match = 1
		end
		return retval,buff,match
   end
   
   def queue_messages(controller, controllername, buffer)

	  buff = buffer.dup
	  
	  #find start of message
	  while buff[0..1] != '02' and buff.length >= 2
		$log.error("Finding start of message: Controller:#{controller} #{buff} Lastread:#{@controllers[s]['lastread']}")
		len = buff.length
		buff = buff[2..len]
	  end

	  e = []

	  if buff.length >= 4	
		match = 1
		begin
			event = buff[0..3]
			case event
			when '0250'
				m,buff,match = parse(buff,22)
				e << m if !m.empty?
			when  '0251'
				m,buff,match = parse(buff,50) 
				e << m if !m.empty?
			when '0252'
				m,buff,match = parse(buff,8) 
				e << m if !m.empty?
			when '0253'
				m,buff,match = parse(buff,20) 
				e << m if !m.empty?
			when '0254'
				m,buff,match = parse(buff,6) 
				e << m if !m.empty?
			when '0255'
				m,buff,match = parse(buff,4) 
				e << m if !m.empty?
			when '0256'
				m,buff,match = parse(buff,14) 
				e << m if !m.empty?
			when '0257'
				m,buff,match = parse(buff,20) 
				e << m if !m.empty?
			when '0258'
				m,buff,match = parse(buff,6) 
				e << m if !m.empty?
			when '0260'
				m,buff,match = parse(buff,18) 
				e << m if !m.empty?
			when '0261'
				m,buff,match = parse(buff,12) 
				e << m if !m.empty?
			when '0262'
				if buff.length >=11
					flag = buff[10..11]
					if flag.hex & 16  == 16
						m,buff,match = parse(buff,46)
						e << m if !m.empty?
					else
						m,buff,match = parse(buff,18)
						e << m if !m.empty?
					end
				else
					match = 0
				end
			when '0263'
				m,buff,match = parse(buff,10) 
				e << m if !m.empty?
			when '0264'
				m,buff,match = parse(buff,10) 
				e << m if !m.empty?
			when '0265'
				m,buff,match = parse(buff,6) 
				e << m if !m.empty?
			when '0266'
				m,buff,match = parse(buff,12) 
				e << m if !m.empty?
			when '0267'
				m,buff,match = parse(buff,6) 
				e << m if !m.empty?
			when '0268'
				m,buff,match = parse(buff,8) 
				e << m if !m.empty?
			when '0269'
				m,buff,match = parse(buff,6) 
				e << m if !m.empty?
			when '026A'
				m,buff,match = parse(buff,6) 
				e << m if !m.empty?
			when '026B'
				m,buff,match = parse(buff,8) 
				e << m if !m.empty?
			when '026C'
				m,buff,match = parse(buff,6) 
				e << m if !m.empty?
			when '026D'
				m,buff,match = parse(buff,6) 
				e << m if !m.empty?
			when '026E'
				m,buff,match = parse(buff,6) 
				e << m if !m.empty?
			when '026F'
				m,buff,match = parse(buff,24) 
				e << m if !m.empty?
			when '0270'
				m,buff,match = parse(buff,8) 
				e << m if !m.empty?
			when '0271'
				m,buff,match = parse(buff,10) 
				e << m if !m.empty?
			when '0272'
				m,buff,match = parse(buff,6) 
				e << m if !m.empty?
			when '0273'
				m,buff,match = parse(buff,12) 
				e << m if !m.empty?
			else
				match = 0
				if buff.length >= 2
					$log.error("Align message buffer: Controller:#{controller} #{buff} Lastread:#{@controllers[s]['lastread']}")
					len = buff.length
					buff = buff[2..len]
				end
			end
		end while match == 1
	  end
      
      time = Time.new

	  last = e.length - 1
      e.each_index {|i|
      if !e[i].empty?
         message = Hash.new
         message['Controller'] = controller
         message['Controllername'] = controllername
         message['Time'] = time
         message['Event'] = ''
         message['Description'] = ''
         message['From'] = ''
         message['To'] = ''
         message['Flags'] = ''
         message['Command'] = ''
         message['Extended'] = ''
         message['Category'] = ''
         message['Subcategory'] = ''
         message['Version'] = ''
         message['Status'] = ''
         message['Linkcode'] = ''

         event = e[i][0..3]
         case event 
         when '0250' # received standard message
            arr = e[i].scan(/^(....)(......)(......)(..)(....)$/)
            if arr.length == 1 and arr[0].length == 5
               message['Event'] = arr[0][0]
               message['Description'] = 'Std Message'
               message['From'] = arr[0][1]
               message['To'] = arr[0][2]
               message['Flags'] = arr[0][3]
               message['Command'] = arr[0][4]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '0251' # received extended message
            arr = e[i].scan(/^(....)(......)(......)(..)(....)(............................)$/)
            if arr.length == 1 and arr[0].length == 6
               message['Event'] = arr[0][0]
               message['Description'] = 'Ext Message'
               message['From'] = arr[0][1]
               message['To'] = arr[0][2]
               message['Flags'] = arr[0][3]
               message['Command'] = arr[0][4]
               message['Extended'] = arr[0][5]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '0253' # All Linking Completed
            arr = e[i].scan(/^(....)(..)(..)(......)(..)(..)(..)$/)
            if arr.length == 1 and arr[0].length == 7
               message['Event'] = arr[0][0]
               message['Description'] = 'All Linking Completed'
               message['Linkcode'] = arr[0][1]
               message['To'] = arr[0][2]
               message['From'] = arr[0][3]
               message['Category'] = arr[0][4]
               message['Subcateory'] = arr[0][5]
               message['Status'] = arr[0][6]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '0254' # Button Event Report
            arr = e[i].scan(/^(....)(..)$/)
            if arr.length == 1 and arr[0].length == 2
               message['Event'] = arr[0][0]
               message['Description'] = 'Button Event Report'
               message['Status'] = arr[0][1]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '0256' # ALL-Link Cleanup Failure Report
            arr = e[i].scan(/^(....)(..)(......)$/)
            if arr.length == 1 and arr[0].length == 3
               message['Event'] = arr[0][0]
               message['To'] = arr[0][1]
               message['From'] = arr[0][2]
               message['Description'] = 'ALL-Link Cleanup Failure Report'
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '0257' # All-Link Report
            arr = e[i].scan(/^(....)(..)(..)(......)(......)$/)
            if arr.length == 1 and arr[0].length == 5
               message['Event'] = arr[0][0]
               message['Description'] = 'All-Link Report'
               message['From'] = arr[0][3]
               message['To'] = arr[0][2]
               message['Flags'] = arr[0][1]
               message['Command'] = arr[0][4]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '0258' # ALL-Link Cleanup Status Report
            arr = e[i].scan(/^(....)(.*)$/)
            if arr.length == 1 and arr[0].length == 2
               message['Event'] = arr[0][0]
               message['Description'] = 'All-Link Cleanup'
               message['Status'] = arr[0][1]
            else
 				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '0260' # Get IM Info
            arr = e[i].scan(/^(....)(......)(..)(..)(..)(..)$/)
            if arr.length == 1 and arr[0].length == 6
               message['Event'] = arr[0][0]
               message['Description'] = 'Get IM Info'
               message['From'] = arr[0][1]
               message['Category'] = arr[0][2]
               message['Subcategory'] = arr[0][3]
               message['Version'] = arr[0][4]
               message['Status'] = arr[0][5]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '0261' # Scene Command
            arr = e[i].scan(/^(....)(..)(..)(.*)$/)
            if arr.length == 1 and arr[0].length == 4
               message['Event'] = arr[0][0]
               message['Description'] = 'Scene Message'
               message['From'] = arr[0][1]
               message['Command'] = arr[0][2]
               message['Status'] = arr[0][3]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '0262' # Send Message                                         
            case e[i].length
            when 46  # extended message
               arr = e[i].scan(/^(....)(......)(..)(....)(............................)(..)$/) 
               if arr.length == 1 and arr[0].length == 6
                  message['Event'] = arr[0][0]
                  message['Description'] = 'Send Message'
                  message['To'] = arr[0][1]
                  message['Flags'] = arr[0][2]
                  message['Command'] = arr[0][3]
                  message['Extended'] = arr[0][4]
                  message['Status'] = arr[0][5]
				  if message['Status'] == "15"  #nack of a message should resend
				    command = "0262#{message['To']}#{message['Flags']}#{message['Command']}#{message['Extended']}"
				    $log.info("Retrying insteon command #{@controllers[@devices[message['To']]['controller']]['name']} #{command} #{message['Extended']} delay 1")
				    self.SendPLM(@devices[message['To']]['controller'],command,desc='Insteon Retry',1)
				  end
               end
            when 18  # standard message
               arr = e[i].scan(/^(....)(......)(..)(....)(..)$/) 
               if arr.length == 1 and arr[0].length == 5
                  message['Event'] = arr[0][0]
                  message['Description'] = 'Send Message'
                  message['To'] = arr[0][1]
                  message['Flags'] = arr[0][2]
                  message['Command'] = arr[0][3]
                  message['Status'] = arr[0][4]
				  if message['Status'] == "15"  #nack of a message should resend
				    command = "0262#{message['To']}#{message['Flags']}#{message['Command']}"
				    $log.info("Retrying insteon command #{@controllers[@devices[message['To']]['controller']]['name']} #{command} delay 1")
				    self.SendPLM(@devices[message['To']]['controller'],command,desc='Insteon Retry',1)
				  end
			   end
             else
				$log.error("Mis-aligned message: #{e[i]}")
             end
         when '0265' # Cancel All-linking
            arr = e[i].scan(/^(....)(..)$/)
            if arr.length == 1 and arr[0].length == 2
               message['Event'] = arr[0][0]
               message['Description'] = 'Cancel All-linking'
               message['Status'] = arr[0][1]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '0266' # Set Host Device Category
            arr = e[i].scan(/^(....)(..)(..)(..)(..)$/)
            if arr.length == 1 and arr[0].length == 5
               message['Event'] = arr[0][0]
               message['Description'] = 'Set Host Device Category'
               message['Category'] = arr[0][1]
               message['Subcategory'] = arr[0][2]
               message['Version'] = arr[0][3]
               message['Status'] = arr[0][4]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '0269' # Get First ALL-Link
            arr = e[i].scan(/^(....)(..)$/)
            if arr.length == 1 and arr[0].length == 2
               message['Event'] = arr[0][0]
               message['Description'] = 'Get First ALL-Link'
               message['Status'] = arr[0][1]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '026A' # Get Next ALL-Link
            arr = e[i].scan(/^(....)(..)$/)
            if arr.length == 1 and arr[0].length == 2
               message['Event'] = arr[0][0]
               message['Description'] = 'Get Next ALL-Link'
               message['Status'] = arr[0][1]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '026B' # Set IM Configuration
            arr = e[i].scan(/^(....)(..)(..)$/)
            if arr.length == 1 and arr[0].length == 3
               message['Event'] = arr[0][0]
               message['Command'] = arr[0][1]
               message['Description'] = 'Set IM Configuration'
               message['Status'] = arr[0][2]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         when '026F' # Manage ALL-Link Record
            #                 026F  20  A2  01  13DED1  00  05  38  06
            arr = e[i].scan(/^(....)(..)(..)(..)(......)(..)(..)(..)(..)$/)
            if arr.length == 1 and arr[0].length == 9
               message['Event'] = arr[0][0]
               message['Command'] = arr[0][1]
               message['Flags'] = arr[0][2]
               message['To'] = arr[0][3]
               message['From'] = arr[0][4]
               message['Category'] = arr[0][5]
               message['Subcategory'] = arr[0][6]
               message['Version'] = arr[0][7]
               message['Description'] = 'Manage ALL-Link Record'
               message['Status'] = arr[0][8]
            else
				$log.error("Mis-aligned message: #{e[i]}")
            end
         else
			$log.error("Unknown message: #{e[i]}")
         end
         if !message['Event'].empty?
            recvpush(message)
         end
      end
   }
   return buff
   end
   
   def setclock()
   end

   def getcontrollers()
        return @controllers
   end

   def getcontroller(device)
        return @devices[device]['controller']
   end

   def getdevices()
        return @devices
   end

   def getdeviceinfo(device)
        return @devices[device]
   end

   def sendcommand(device,cmd,delay=0)
      controller = @devices[device]['controller']
      path = "0262#{device}0F#{cmd}"  
      SendPLM(controller,path,'Send Command',delay)
   end

   def sendExtCommand(device,cmd,delay=0)
      controller = @devices[device]['controller']
      path = "0262#{device}1F#{cmd}"  
      SendPLM(controller,path,'Send Extended Command',delay)
   end
   
   def SendGetFirst(controller)
      path = "0269"  
      SendPLM(controller,path,'Send Get First')
   end

   def SendGetNext(controller)
      path = "026A"  
      SendPLM(controller,path,'Send Get Next')
   end

   def SendRemoteSetMSB(controller,device,msb)
      path = "0262#{device}0F28#{msb}"  
      SendPLM($controller,path,'Send Remote Set MSB')
   end

   def SendRemotePeek(controller,device,offset)
      path = "0262#{device}0F2B#{offset}"  
      SendPLM(controller,path,'Send Remote Peek')
   end

   def SendMonitor(controller)
      path = "026B40"  
      SendPLM(controller,path,'Send Monitor')
   end

   def SendLightStatus(device,delay=10)
      controller = @devices[device]['controller']
      path = "0262#{device}0F1900"  
      SendPLM(controller,path,'Send Light status',delay)
   end

   def SendIdRequest(controller,device)
      path = "0262#{device}0F1000"  
      SendPLM(controller,path,'Send ID Request')
   end

   def SendEngineVersion(controller,device)
      path = "0262#{device}0F0D00"  
      SendPLM(controller,path,'Send Engine Version')
   end

   def SendGetIMinfo(controller)
      path = "0260"  
      SendPLM(controller,path,'Get IM Info')
   end

   def SendManageLink(controller,record)
      path = "026F#{record}"  
      SendPLM(controller,path,'Send Manage Link')
   end

   def SendPing(controller,device)
      path = "0262#{device}0F1F00"  
      SendPLM(controller,path,'Send Ping')
   end

   def ReadAllLinkDatabase(controller,device,address='0000')
      d1  = '00' # unused
      d2  = '00' # read
      d3  = address # address is 2 bytes
      #d5  = '01' # read one record
      d5  = '00' # read all records
      d6  = '00' # unused
      d7  = '00' # unused
      d8  = '00' # unused
      d9  = '00' # unused
      d10 = '00' # unused
      d11 = '00' # unused
      d12 = '00' # unused
      d13 = '00' # unused
      d14 = '00' # unused
	  command = "2F00#{d1}#{d2}#{d3}#{d5}#{d6}#{d7}#{d8}#{d9}#{d10}#{d11}#{d12}#{d13}#{d14}"
      
      path = "0262#{device}1F#{command}"  
      SendPLM(controller,path,'Read All Link Database')
   end
   
   def checksum(h) 
		i = 0
		h.scan(/[0-9a-f]{2}/i).each {| x |
			i += x.hex
		}
		(((~i) + 1) & 255).to_s(16).upcase
   end

   def softlink(controller, group, fdevice, tdevice) 
		# type = 00 if the PLM will be the responder, 01 if the PLM will be the controller, or 03 if the first device to go into linking mode will be the controller
		cancel = 0
		if fdevice == controller
			command = "026401#{group}"
			$controller.WritePLM(controller,command)
			cancel = 1
			sleep(1)
		else
			# 02 62 [address] 3F 09 [group] 00 00 00 00 00 00 00 00 00 00 00 00 00 [checksum]
			command = "3F09#{group}0000000000000000000000000000"
			$controller.WritePLM(controller,"0262#{fdevice}#{command}")
			sleep(3)
		end
		if tdevice == controller
			command = "026400#{group}"
			$controller.WritePLM(controller,command)
			cancel = 1
			sleep(1)
		else
			# 02 62 [address] 3F 09 [group] 00 00 00 00 00 00 00 00 00 00 00 00 00 [checksum]
			command = "3F09#{group}FF000000000000000000000000"
			checksum = $controller.checksum(command)
			#checksum = '00'
			$controller.WritePLM(controller,"0262#{tdevice}#{command}#{checksum}")
			sleep(1)
		end

		if cancel
			command = "0265"
			#$controller.WritePLM(controller,command)
		end
		
		while !recvempty()
			message = recvpop()
			pp message
        end

   end

   def softunlink(controller, group, fdevice, tdevice) 
		# type = 00 if the PLM will be the responder, 01 if the PLM will be the controller, or 03 if the first device to go into linking mode will be the controller
		cancel = 0
		if fdevice == controller
			command = "0264FF#{group}"
			$controller.WritePLM(controller,command)
			cancel = 1
			sleep(3)
		else
			# 02 62 [address] 3F 09 [group] 00 00 00 00 00 00 00 00 00 00 00 00 00 [checksum]
			command = "3F0A#{group}0000000000000000000000000000"
			$controller.WritePLM(controller,"0262#{fdevice}#{command}")
			sleep(3)
		end
		if tdevice == controller
			command = "0264FF#{group}"
			$controller.WritePLM(controller,command)
			cancel = 1
			sleep(3)
		else
			# 02 62 [address] 3F 09 [group] 00 00 00 00 00 00 00 00 00 00 00 00 00 [checksum]
			command = "3F0A#{group}0000000000000000000000000000"
			$controller.WritePLM(controller,"0262#{tdevice}#{command}")
			sleep(3)
		end

		if cancel
			command = "0265"
			$controller.WritePLM(controller,command)
		end
		
		message = recvpop()
		while message
			pp message
			message = recvpop()
        end

   end

   def WriteAllLinkDatabase(controller,device,address,record)
      d1  = '00' # unused
      d2  = '02' # write
      d3  = address # address is 2 bytes
      d5  = '08' # write 8 bytes
      d6  = record # ALDB record to write 8 bytes
      d14 = '00' # unused on engine 0 and 1, checksum on 2
	  command = "2F00#{d1}#{d2}#{d3}#{d5}#{d6}#{d14}"
      
      path = "0262#{device}1F#{command}"  
      SendPLM(controller,path,'Read All Link Database')
   end

   def WritePLM(controller,path,desc='Plm write error')
      $log.debug("WritePLM #{@controllers[controller]['name']} #{path}")

      @controllers[controller]['lastwrite'] = path
      @controllers[controller]['lastwritetime'] = Time.now
	  apath = path.scan(/[0-9a-f]{2}/i)      

	  # update the hop count
	  if apath[0] == '02' and apath[1] == '62'
		apath[5][1] = (@maxhops * 4 + @maxhops).to_s(16).upcase
	  end

      line=''
	  apath.each { |x|
		line += x.hex.chr
	  }
      #while !path.empty?
      #  line += path[0..1].hex.chr
      #  path = path[2..path.length]
      #end

      begin
		if @controllers[controller]['socket'] == nil
			opensocket(controller)
		end
		@controllers[controller]['socket'].write line
		#@controllers[controller]['socket'].flush
      rescue 
            $log.error("Socket write error for #{controller} #{@controllers[controller]['friendlyname']} #{@controllers[controller]['host']} #{@controllers[controller]['port']} #{$!} #{$@[0]} Line: #{$.}")
			closesocket(controller)
            sleep(1)
			opensocket(controller)
            retry
      end
   end
   
   def SendPLM(controller,path,desc='Send error',delay=0)

   # check for extended message and add checksum to support i2cs devices
	  #           1         2         3         4
	  # 01234567890123456789012345678901234567890123
	  # 0262154DE41F2F000000000000000000000000000000
	  if path[0..3] == '0262'
		flag = path[10..11]
		if flag.hex & 16  == 16
			path[42..43] = checksum(path[12..41])
		end
	  end

	  message = Hash.new
      message['Controller'] = controller
      message['Path'] = path
      message['ErrorDesc'] = desc
      message['Time'] = Time.now + delay

      $log.debug("SendPLM  #{@controllers[controller]['name']} Path:#{path} Time now:#{Time.now} Time delay:#{Time.now + delay}")
	  sendpush(message)

	  
	  if path[0..3] == "0262" and (path[12..13] == "11" or path[12..13] == "13")
		device = path[4..9]
		case @devices[device]['category']
			when '01', '02'
			command = "0262#{device}0F1900"
			message = Hash.new
			message['Controller'] = @devices[device]['controller']
			message['Path'] = command
			message['ErrorDesc'] = 'Insteon status'
			message['Time'] = Time.now + delay +2
			$log.info("Sending insteon status #{@controllers[@devices[device]['controller']]['name']} #{command} delay #{delay+2}")
			sendpush(message)
		end
	  end
	  
   end

   def getIMinfo(controller)
      begin
         retval = {}
         clearRecvQueue()
         Timeout.timeout 30 do
            SendGetIMinfo(controller)
            ackfound = ''
            while ackfound != '06' and ackfound != '15'
               if message = recvpop()
                  if message['Event'] == '0260' and message['Controller'] == controller
                     ackfound = message['Status']
                  end
               end
               Thread.pass
            end
            if ackfound == '06'
               retval['Address'] = message['From']
               retval['Type'] = "#{message['Category']}#{message['Subcategory']}#{message['Version']}"
            end
            return retval
         end
      rescue Timeout::Error
         $log.error("getIMinfo for controller #{controller} timeout...retrying")
         retry
      end
   end

   def getRequestID(controller,device)
      begin
         retval = false
         clearRecvQueue()
         Timeout.timeout 30 do
            SendIdRequest(controller,device)
            ackfound = ''
            while ackfound != '06' and ackfound != '15'
               if message = recvpop()
                  if message['Event'] == '0262' and message['To'] == device and message['Controller'] == controller
                     ackfound = message['Status']
                  end
               end
               Thread.pass
            end
            if ackfound == '06'
               recfound = false
               while recfound == false
                  if message = recvpop()
                     if message['Event'] == '0250' and message['From'] == device and message['Flags'].hex & 32 == 0 and message['Controller'] == controller
                        retval = message['To']
                        recfound = true
                     end
                  end
                  Thread.pass
               end
            end
            return retval
         end
      rescue Timeout::Error
         $log.error("getRequestID for controller #{controller} device #{device} timeout...retrying")
         retry
      end
   end

   def getEngineVersion(controller,device)
      begin
         retval = false
         clearRecvQueue()
         Timeout.timeout 30 do
            SendEngineVersion(controller,device)
            ackfound = ''
            while ackfound != '06' and ackfound != '15'
               if message = recvpop()
                  if message['Event'] == '0262' and message['To'] == device and message['Controller'] == controller
                     ackfound = message['Status']
                  end
               end
               Thread.pass
            end
            if ackfound == '06'
               recfound = false
               while recfound == false
                  if message = recvpop()
                     if message['Event'] == '0250' and message['From'] == device and message['Controller'] == controller
                        retval = message['Command'][2..3]
                        recfound = true
                     end
                  end
                  Thread.pass
               end
            end
            return retval
         end
      rescue Timeout::Error
         $log.error("getEngineVersion for controller #{controller} device #{device} timeout...retrying")
         retry
      end
   end

   def remoteSpiderV1(controller,device)
      begin
         Timeout.timeout 180 do
            linkrecords = []
            remoteDBOffsetMSB = 0x0F # initial offset
            remoteDBOffsetLSB = 0xF8 # initial LSB offset

            clearRecvQueue()
                  
            SendRemoteSetMSB(controller,device,"%02X"%remoteDBOffsetMSB)

            ackfound = ''
            while ackfound != '06' and ackfound != '15'
               if message = recvpop()
                  if message['Event'] == '0262' and message['To'] == device and message['Controller'] == controller
                     if message['Status'] != '06'
                        more = false
                     end
                     ackfound = message['Status']
                  end
               end
            end
            if ackfound == '06'
               recfound = false
               while recfound == false
                  if message = recvpop()
                     if message['Event'] == '0250' and message['Controller'] == controller
                        morepeek = true
                        while morepeek == true
                           peekrecord = ''
      
                           for x in 0..7
                              SendRemotePeek(controller,device,"%02X"%(remoteDBOffsetLSB + x))
                              ackfound = ''
                              while ackfound != '06' and ackfound != '15'
                                 if message = recvpop()
                                    if message['Event'] == '0262' and message['To'] == device and message['Controller'] == controller
                                       if message['Status'] != '06'
                                          more = false
                                       end
                                       ackfound = message['Status']
                                    end
                                 end
                                 Thread.pass
                              end
                              if ackfound == '06'
                                 peekfound = false
                                 while !peekfound
                                    if message = recvpop()
                                       if message['Event'] == '0250' and message['From'] == device and message['Controller'] == controller
                                          peekfound = true
                                          peekrecord = peekrecord + message['Command'][2..3]
                                       end
                                    end
                                    Thread.pass
                                 end
                              end
                           end
                           peekflag = peekrecord[0..1]
                           peekgroup = peekrecord[2..3]
                           peekdevice = peekrecord[4..9]
                           peektype = peekrecord[10..15]
                           address = "#{"%02X"%remoteDBOffsetMSB}#{"%02X"%remoteDBOffsetLSB}"
                           $log.info("SpiderRemote device #{device} ALDB Flag:#{peekflag} Group:#{peekgroup} Device:#{peekdevice} Type:#{peektype} Address:#{address}")
                           if (peekflag.hex & 0x02) == 0x00 # High water mark
                              morepeek = false
                           end
                           if (peekflag.hex & 0x80) == 0x80 # Inuse
                              linkrecords << {'To'=>peekdevice,'From'=>device, 'Group'=>peekgroup, 'Flags' => peekflag,'Linkdata'  => peektype,'Address'  => address} 
                           end
                           if remoteDBOffsetLSB == 0x00
                              #OffsetMSB needs to be decreased, and LSB needs reset.
                              remoteDBOffsetMSB = remoteDBOffsetMSB - 1
                              remoteDBOffsetLSB = 0xFF # the next line will decrease this by 8
                           end
                           # decrease DBOffsetLSB by 0x08
                           remoteDBOffsetLSB = remoteDBOffsetLSB - 0x08
                        end
                        recfound = true
                     end
                  end
               end
            end
            return linkrecords
         end
      rescue Timeout::Error
         $log.error("remoteSpiderV1 for controller #{controller} device #{device} timeout...retrying")
         retry
      end
   end

   def remoteSpider(controller,device)
      begin
         Timeout.timeout 30 do
            linkrecords = []
            clearRecvQueue()

            nextaddress = '0000'            
            more = true                  
            while more
               ReadAllLinkDatabase(controller,device,nextaddress)
               ackfound = ''
               while ackfound != '06' and ackfound != '15'
                  if message = recvpop()
                     if message['Event'] == '0262' and message['To'] == device and message['Controller'] == controller
                        if message['Status'] != '06'
                           more = false
                        end
                        ackfound = message['Status']
                     end
                  end
                  Thread.pass
               end
               if ackfound == '06'
                  recfound = false
                  while recfound == false
                     if message = recvpop()
                        if message['Event'] == '0251' and message['From'] == device and message['Controller'] == controller
                           peekaddress    = message['Extended'][4..7]
                           nextaddress    = "%04X"%(message['Extended'][4..7].hex - 8)
                           peekflag   = message['Extended'][10..11]
                           peekgroup  = message['Extended'][12..13]
                           peekdevice = message['Extended'][14..19]
                           peektype   = message['Extended'][20..25]
                           if (peekflag.hex & 0x02) == 0x00 # High water mark
                              $log.info("SpiderRemote device #{device} ALDB Flag:#{peekflag} Address:#{peekaddress} end of records")
                              more = false
                              recfound = true
                           end
                           if (peekflag.hex & 0x80) == 0x80 # Inuse
                                $log.info("SpiderRemote device #{device} ALDB Flag:#{peekflag} Group:#{peekgroup} Device:#{peekdevice} Type:#{peektype} Address:#{peekaddress}")
                                linkrecords << {'To'=>peekdevice,'From'=>device, 'Group'=>peekgroup, 'Flags' => peekflag,'Linkdata'  => peektype,'Address'  => peekaddress} 
                           end
                        end
                        Thread.pass
                     end
                  end
               end
            end
            return linkrecords
         end
      rescue Timeout::Error
         $log.error("remoteSpider for controller #{controller} device #{device} timeout...retrying")
         retry
      end
   end
   
   def remoteWriteALDB(controller,device,records)
      begin
         Timeout.timeout 30 do
            # append end of ALDB to the list
            records << {'To'=>'000000', 'Group'=>'00', 'Flags' =>'00','Linkdata'  =>'000000'} 
            clearRecvQueue()

            errorsfound = false
            nextaddress = '0FFF'            
            records.each { |i|
               linkdata = "#{i['Flags']}#{i['Group']}#{i['To']}#{i['Linkdata']}"
               $log.info("remote write ALDB controller #{controller} device #{device} address #{nextaddress} link #{linkdata}")
               WriteAllLinkDatabase(controller,device,nextaddress,linkdata)
               ackfound = ''
               while ackfound != '06' and ackfound != '15'
                  if message = recvpop()
                     if message['Event'] == '0262' and message['To'] == device and message['Controller'] == controller
                        if message['Status'] != '06'
                          $log.error("remote write ALDB controller #{controller} device #{device} address #{nextaddress} link #{linkdata}")
                          errorsfound = true
                        end
                        ackfound = message['Status']
                     end
                  end
                  Thread.pass
               end
               nextaddress    = "%04X"%(nextaddress.hex - 8)
            }

            return errorsfound
         end
      rescue Timeout::Error
         $log.error("remoteWriteALDB for controller #{controller} device #{device} timeout...retrying")
         retry
      end
   end

   def scanController(controller)
      begin
         Timeout.timeout 30 do
            linkrecords = []
            clearRecvQueue()
            SendGetFirst(controller)
            more = true
            while more
               ackfound = ''
               while ackfound != '06' and ackfound != '15'
                  if message = recvpop()
                     if message['Event'] == '0269' or message['Event'] == '026A' and message['Controller'] == controller
                        if message['Status'] != '06'
                           more = false
                        end
                        ackfound = message['Status']
                     elsif message['Event'] == '0257' and message['Controller'] == controller
						recvpush(message)
					 end
                  end
                  Thread.pass
               end
               if ackfound == '06'
                  recfound = false
                  while recfound == false
                     if message = recvpop()
                        if message['Event'] == '0257' and message['Controller'] == controller
                           linkrecords << {'To'=>message['From'],'From'=>controller, 'Group'=>message['To'], 'Flags' => message['Flags'],'Linkdata'  => message['Command'],'Type'  => nil,'Engine'  => nil} 
						   $log.info("Scan for controller #{controller} To #{message['From']} From #{controller} Group #{message['To']} Flags #{message['Flags']} Linkdata #{message['Command']} Type #{message['Command']}")
                           recfound = true
                        end
                     end
                     Thread.pass
                  end
               end
               if more 
				self.SendGetNext(controller)
               end
            end
            return linkrecords
         end
      rescue Timeout::Error
         $log.error("scancontroller for controller #{controller} timeout...retrying")
         retry
      end
   end

   def ExistsInController(controller,flags,devicegroup,device,linkdata)
      begin
         retval = false
         clearRecvQueue()
         Timeout.timeout 30 do
            SendManageLink(controller,"00#{flags}#{devicegroup}#{device}#{linkdata}")
            ackfound = ''
            while ackfound != '06' and ackfound != '15'
               if message = recvpop()
                  if message['Event'] == '026F'  and message['Controller'] == controller
                     ackfound = message['Status']
                  end
               end
               Thread.pass
            end
            if ackfound == '06'
               retval = true
            else
               retval = false
            end
            return retval
         end
      rescue Timeout::Error
         $log.error("Exists In Controller timeout...retrying")
         retry
      end
   end

   def DeleteFromController(controller,flags,devicegroup,device,linkdata)
      begin
         retval = false
         clearRecvQueue()
         Timeout.timeout 30 do
            SendManageLink(controller,"80#{flags}#{devicegroup}#{device}#{linkdata}")
            ackfound = ''
            while ackfound != '06' and ackfound != '15'
               if message = recvpop()
                  if message['Event'] == '026F'  and message['Controller'] == controller
                     ackfound = message['Status']
                  end
               end
               Thread.pass
            end
            if ackfound == '06'
               retval = true
            else
               retval = false
            end
            return retval
         end
      rescue Timeout::Error
         $log.error("Delete From Controller timeout...retrying")
         retry
      end
   end

   def AddToController(controller,flags,devicegroup,device,linkdata)
      begin
         retval = false
         clearRecvQueue()
         Timeout.timeout 30 do
            if flags == 'E2'
                cmd = '40'
            else
                cmd = '41'
            end
            SendManageLink(controller,"#{cmd}#{flags}#{devicegroup}#{device}#{linkdata}")
            ackfound = ''
            while ackfound != '06' and ackfound != '15'
               if message = recvpop()
                  if message['Event'] == '026F' and message['Controller'] == controller 
                     ackfound = message['Status']
                  end
               end
               Thread.pass
            end
            if ackfound == '06'
               retval = true
            else
               retval = false
            end
            return retval
         end
      rescue Timeout::Error
         $log.error("Add To Controller Controller timeout...retrying")
         retry
      end
   end

   def Ping(controller,device)
      retries = 0
      begin
         retval = false
         clearRecvQueue()
         Timeout.timeout 5 do
            SendPing(controller,device)
            ackfound = ''
            while ackfound != '06' and ackfound != '15'
               if message = recvpop()
                  if message['Event'] == '0262' and message['To'] == device  and message['Command'] == '1F00' and message['Controller'] == controller
                     ackfound = message['Status']
                  end
               end
               Thread.pass
            end
            if ackfound == '06'
               recfound = false
               while recfound == false
                  if message = recvpop()
                     if message['Event'] == '0250' and message['From'] == device and message['Controller'] == controller
                        retval = true
                        recfound = true
                     end
                  end
                  Thread.pass
               end
            end
            return retval
         end
      rescue Timeout::Error
         $log.error("Ping timeout for controller #{controller} device #{device}...retrying")
         retries += 1
         if retries == 2
            return false
         else
            retry
         end
      end
   end

end