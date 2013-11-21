#!/usr/bin/env ruby
require 'rubygems'
require 'net/smtp'
require '/usr/src/insteon/insteonConfig.rb'

#$log.level = Logger::DEBUG

$log.info('Starting...')


$log.info('Opening database')
$mysql = Mysql::new($dbhost, $dbusername, $dbpassword, $dbtable)

trap("INT") { 
	puts "Shutting down..."
	$log.info('Shutting down...')
	# TODO close the controller sockets
	$log.close
	$mysql.close
	exit
}

def parse_buffstatus(e)

   logdata = "#{e['Controllername']} Message: #{e['Description']}(#{e['Event']}) "
   case e['Event'] 
		when '0250' # received standard message
			logdata += "From: #{e['From']} "
			logdata += "To: #{e['To']} "
			logdata += "Flags:[" + parse_flag(e['Flags']) + '] '
			logdata += "Command: #{e['Command']} "
			deviceinfo = $controller.getdeviceinfo(e['From'])
			if deviceinfo
				if e['Flags'].hex & 32 == 32
					case deviceinfo['category']
					when '01', '02'
						if  e['Command'][2..3].hex > 0x00

							$devices[e['From']]['state'] = 'ON'
							$devices[e['From']]['brightness'] = hextopercent(e['Command'][2..3])
							$devices[e['From']]['lastupdate'] = Time.now

							query = "UPDATE jos_insteondevices SET state='ON',brightness='#{hextopercent(e['Command'][2..3])}',lastupdate=NOW() WHERE device = '#{e['From']}'"
							$log.debug(query)
							res = $mysql.query(query)
						else

							$devices[e['From']]['state'] = 'OFF'
							$devices[e['From']]['brightness'] = hextopercent(e['Command'][2..3])
							$devices[e['From']]['lastupdate'] = Time.now
							
							query = "UPDATE jos_insteondevices SET state='OFF',brightness='#{hextopercent(e['Command'][2..3])}',lastupdate=NOW() WHERE device = '#{e['From']}'"
							$log.debug(query)
							res = $mysql.query(query)
						end
						if  e['Command'][0..1] == '15' or e['Command'][0..1] == '16'
							$controller.SendLightStatus(e['From'],0)
						end
					#when '10'
					#    pp '10'
					#   if  e['Command'][0..1] == '11'
					#        query = "UPDATE jos_insteondevices SET state='ON',brightness='N/A',lastupdate=NOW() WHERE device = '#{e['From']}'"
					#        $log.debug(query)
					#        res = $mysql.query(query)
					#    else                                                                
					#        query = "UPDATE jos_insteondevices SET state='OFF',brightness='N/A',lastupdate=NOW() WHERE device = '#{e['From']}'"
					#        $log.debug(query)
					#        res = $mysql.query(query)
					#    end
					end
				end   
				if (e['Flags'].hex & 192 == 192) && (e['To'] == '000001')
				case deviceinfo['category']+deviceinfo['subcategory']
					when '1001'
						if  e['Command'][0..1] == '11'

							$devices[e['From']]['state'] = 'ON'
							$devices[e['From']]['brightness'] = 'N/A'
							$devices[e['From']]['lastupdate'] = Time.now

							query = "UPDATE jos_insteondevices SET state='ON',brightness='N/A',lastupdate=NOW() WHERE device = '#{e['From']}'"
							$log.debug(query)
							res = $mysql.query(query)
						else                                                                

							$devices[e['From']]['state'] = 'OFF'
							$devices[e['From']]['brightness'] = 'N/A'
							$devices[e['From']]['lastupdate'] = Time.now

							query = "UPDATE jos_insteondevices SET state='OFF',brightness='N/A',lastupdate=NOW() WHERE device = '#{e['From']}'"
							$log.debug(query)
							res = $mysql.query(query)
						end
					end
				end 
			else
				logdata = "Unknown from device #{e['Controllername']} Message: #{e['Description']}(#{e['Event']}) From: #{e['From']} To: #{e['To']} Flags: Flags:[#{parse_flag(e['Flags'])}] Command: #{e['Command']} Status: #{parse_status(e['Status'])}"
				$log.info(logdata)
			end
		when '0251' # received extended message
			deviceinfo = $controller.getdeviceinfo(e['From'])
			if deviceinfo
				if deviceinfo['category'] == '10' and deviceinfo['subcategory'] == '01' and e['Command'] == '2E00'
					logdata += "Motion Sensor Get/Set Extended response "
					logdata += "From: #{e['From']} "
					logdata += "To: #{e['To']} "
					logdata += "Flags:[" + parse_flag(e['Flags']) + '] '
					logdata += "Command: #{e['Command']} "
					logdata += "D1: #{e['Extended'][0..1]} "
					logdata += "D2: #{e['Extended'][2..3]} "
					logdata += "LED level: #{e['Extended'][4..5]} "
					logdata += "Timeout: #{30 + (e['Extended'][6..7].hex.to_i * 30)} "
					logdata += "Dusk/Dawn level: #{e['Extended'][8..9]} "

					logdata += "Option Flags: #{e['Extended'][10..11]} "
					if e['Extended'][10..11].hex & 0x10 == 0x10 
						logdata += "Occupancy mode, "
					end
					if e['Extended'][10..11].hex & 0x08 == 0x08 
						logdata += "LED on, "
					else
						logdata += "LED off, "
					end
					if e['Extended'][10..11].hex & 0x04 == 0x04 
						logdata += "Always on, "
					else
						logdata += "Night only, "
					end
					if e['Extended'][10..11].hex & 0x02 == 0x02 
						logdata += "On/Off "
					else
						logdata += "On only "
					end

					logdata += "D7: #{e['Extended'][12..13]} "
					logdata += "D8: #{e['Extended'][14..15]} "

					logdata += "Jumpers: #{e['Extended'][16..17]} "
					if e['Extended'][16..17].hex & 0x08 == 0x08 
						logdata += "J2 off, "
					else
						logdata += "J2 on, "
					end
					if e['Extended'][16..17].hex & 0x04 == 0x04 
						logdata += "J3 off, "
					else
						logdata += "J3 on, "
					end
					if e['Extended'][16..17].hex & 0x02 == 0x02 
						logdata += "J4 off, "
					else
						logdata += "J4 on, "
					end
					if e['Extended'][16..17].hex & 0x01 == 0x01 
						logdata += "J5 off, "
					else
						logdata += "J5 on, "
					end

					logdata += "D10: #{e['Extended'][18..19]} "
					logdata += "Light level: #{e['Extended'][20..21]} "
					logdata += "Battery level: #{e['Extended'][22..23]} "
					logdata += "D13: #{e['Extended'][24..25]} "
					logdata += "D14: #{e['Extended'][26..27]} "
				else
					logdata += "From: #{e['From']} "
					logdata += "To: #{e['To']} "
					logdata += "Flags:[" + parse_flag(e['Flags']) + '] '
					logdata += "Command: #{e['Command']} "
					logdata += "Extended: #{e['Extended']} "
				end
			else
				logdata = "Unknown from device #{e['Controllername']} Message: #{e['Description']}(#{e['Event']}) From: #{e['From']} To: #{e['To']} Flags: Flags:[#{parse_flag(e['Flags'])}] Command: #{e['Command']} Status: #{parse_status(e['Status'])}"
				$log.info(logdata)
			end
		when '0253' # ALL-Linking Completed
				logdata += "From: #{e['From']} "
				logdata += "Group: #{e['To']} "
				logdata += "Link Code: "
				case e['Linkcode']
				  when '00'
					logdata += "IM is a Responder"
				  when '01'
					logdata += "IM is a Controller"
				  when 'FF'
					logdata += "ALL-Link to the device was deleted"
				  else
					logdata += "Unknown"
				end
				logdata += "Cat: #{e['Category']} "
				logdata += "Sub Cat: #{e['Subcategory']} "
		when '0254' # Button Event Report
				logdata += "Status: "
				case e['Status']
				  when '02'
					logdata += "IM SET Button tapped"
				  when '03'
					logdata += "IM SET Button held"
				  when '04'
					logdata += "IM SET Button released after hold"
				  when '12'
					logdata += "IM Button 2 tapped"
				  when '13'
					logdata += "IM Button 2 held"
				  when '14'
					logdata += "IM Button 2 released after hold"
				  when '22'
					logdata += "IM Button 3 tapped"
				  when '23'
					logdata += "IM Button 3 held"
				  when '24'
					logdata += "IM Button 3 released after hold"
				  else
					logdata += "Unknown"
				end
		when '0256' # ALL-Link Cleanup Failure Report
				logdata += "Group: #{e['To']} "
				logdata += "Device: #{e['From']} "
		when '0257' # All-Link Report
				logdata += "Flags:[" + parse_flag(e['Flags']) + '] '
				logdata += "Group: #{e['To']} "
				logdata += "Device: #{e['From']} "
				logdata += "Data: #{e['Command']} "
		when '0258' # ALL-Link Cleanup Status Report
				logdata += "Status: #{parse_status(e['Status'])}"
		when '0260' # Get IM Info
				logdata += "Device: #{e['From']} "
				logdata += "Cat: #{e['Category']} "
				logdata += "Sub Cat: #{e['Subcategory']} "
				logdata += "Version: #{e['Version']} "
				logdata += "Status: #{parse_status(e['Status'])}"
		when '0261' # Scene Command
				logdata += "Scene: #{e['From']} "
				logdata += "Command: "
				case e['Command']
				  when '11'
					logdata += "On"
				  when '12'
					logdata += "Fast On"
				  when '13'
					logdata += "Off"
				  when '14'
					logdata += "Fast Off"
				  else
					logdata += "Unknown"
				end
				logdata += " Status: #{parse_status(e['Status'])}"
		when '0262' # Send Message                                         
				logdata += "To: #{e['To']} "
				logdata += "Flags:[" + parse_flag(e['Flags']) + '] '
				logdata += "Command: #{e['Command']} "
				if e['Flags'].hex & 16 == 16
				  logdata += e['Extended'] + ' '
				end
				logdata += "Status: #{parse_status(e['Status'])}"
		when '0265' # Cancel All-linking
				logdata += "Status: #{parse_status(e['Status'])} "
		when '0266' # Get IM Info
				logdata += "Cat: #{e['Category']} "
				logdata += "Sub Cat: #{e['Subcategory']} "
				logdata += "Version: #{e['Version']} "
				logdata += "Status: #{parse_status(e['Status'])}"
		when '0269' # Get First ALL-Link
				logdata += "Status: #{parse_status(e['Status'])} "
		when '026A' # Get Next ALL-Link
				logdata += "Status: #{parse_status(e['Status'])} "
		when '026B' # Set IM Configuration
				logdata += "Command: #{e['Command']} "
				logdata += "Status: #{parse_status(e['Status'])} "
		when '026F' # Manage ALL-Link Record
				logdata += "Command: #{e['Command']} "
				logdata += "Flags:[ #{parse_flag(e['Flags'])} " + '] '
				logdata += "Group: #{e['To']} "
				logdata += "Device: #{e['From']} "
				logdata += "Cat: #{e['Category']} "
				logdata += "Sub Cat: #{e['Subcategory']} "
				logdata += "Version: #{e['Version']} "
				logdata += "Status: #{parse_status(e['Status'])} "
		else
				logdata += "Command: #{e['Command']} "
   end
   $log.info(logdata)
  rescue 
      $log.error("Parse Buffer error #{$!}  #{$@[0]} Line: #{$.}")
end              

def parse_status(status)
    case status
      when '06'
        retval = "Ack"
      when '15'
        retval = "Nack"
      when 'FF'
        retval = "Fail '#{status}'"
      else
        retval = "Unknown '#{status}'"
    end
	return retval
end

def parse_flag(flag)
    retval = flag.hex
    f = ''
    if retval & 128 == 128
        f = f +  'B'
    else
        f = f +  'b'
    end
    if retval & 64  == 64
        f = f +  'G'
    else
        f = f +  'g'
    end
    if retval & 32 == 32
        f = f +  'A'
    else
        f = f +  'a'
    end
    if retval & 16  == 16
         f = f +  'E'
	else
        f = f +  'e'
    end
    f = f + ' HL:' 
    if retval & 8 == 8
        f = f +  '1'
    else
        f = f +  '0'
    end
    if retval & 4 == 4
        f = f +  '1'
    else
        f = f +  '0'
    end
    f = f + ' MH:' 
    if retval & 2 == 2
        f = f +  '1'
    else
        f = f +  '0'
    end
    if retval & 1 == 1
        f = f +  '1'
    else
        f = f +  '0'
    end
    
    return f
end
def percenttohex(level)
  # convert from percent to byte
  return "%X" %(level.to_i * 2.55).to_i
end

def hextopercent(level)
  return (level.hex.to_i / 2.55).to_i
end

def checkSchedule(id,time=Time.now)
   date = Date.parse(time.to_s)
   calc = SolarEventCalculator.new(date, BigDecimal.new($long), BigDecimal.new($lat))  
   localSunrise = calc.compute_official_sunrise($timezone) 
   localSunset = calc.compute_official_sunset($timezone)  
   sr = Time.parse(localSunrise.to_s)
   ss = Time.parse(localSunset.to_s)
   
   logdata = ""
   retval = false
   query = "SELECT * from jos_insteonschedules as c WHERE c.id = '#{id}' and c.published = 1"
   $log.debug(query)
   sres = $mysql.query(query)
   if sres.num_rows() > 0
      s = sres.fetch_hash()
      logdata += "Schedule: #{s['description']}, "
      daymatch = false
      case time.wday()
      when 0
         daymatch = true if s['dsun'] == '1'
      when 1
         daymatch = true if s['dmon'] == '1' 
      when 2
         daymatch = true if s['dtue'] == '1'
      when 3
         daymatch = true if s['dwed'] == '1'
      when 4
         daymatch = true if s['dthu'] == '1'
      when 5
         daymatch = true if s['dfri'] == '1'
      when 6
         daymatch = true if s['dsat'] == '1'
      end
      if daymatch
         logdata += "Days matched, "
         case s['timecode'] 
         when '0' # timecode 0 = before time
            logdata += "Schedule before time "
            stime = Time.parse("#{time.strftime("%Y-%m-%d")} #{s['stime']}")
            #$log.info("Times ct #{time.strftime("%Y/%m/%d %I:%M%p")} at #{stime.strftime("%Y/%m/%d %I:%M%p")} ")
            if (time - stime) <= 0
               retval = true
               #$log.info("Time match #{time} #{stime}")
            end
         when '1' # timecode 1 = After time
            logdata += "Schedule After time "
            stime = Time.parse("#{time.strftime("%Y-%m-%d")} #{s['stime']}")
            #$log.info("Times ct #{time.strftime("%Y/%m/%d %I:%M%p")} at #{stime.strftime("%Y/%m/%d %I:%M%p")} ")
            if time >= stime
               retval = true
               #$log.info("Time match #{time} #{stime}")
            end
         when '2' # timecode 2 = at Time
            logdata += "Schedule AT time "
            stime = Time.parse("#{time.strftime("%Y-%m-%d")} #{s['stime']}")
            #$log.info("Times ct #{time.strftime("%Y/%m/%d %I:%M%p")} at #{stime.strftime("%Y/%m/%d %I:%M%p")} diff #{time - stime}")
            diff = time - stime
            if (diff >= 0 && diff <= 15.5)
               retval = true
               #$log.info("Time match #{time} #{stime}")
            end
         when '3' # timecode 3 = before sunrise
            logdata += "Schedule before sunrise "
            
            if time >= ss
               sr += 60*60*24  # add day for sunrise tomorrow
            end
            #$log.info("Times sr #{sr.strftime("%Y/%m/%d %I:%M%p")} ss #{ss.strftime("%Y/%m/%d %I:%M%p")} ")
            if time <= sr - (s['timeoffset'].to_i * 60)
               retval = true
               #$log.info("Time match #{time} #{stime}")
            end
         when '4' # timecode 4 = after sunrise
            logdata += "Schedule after sunrise "
            if time >= ss
               sr += 60*60*24  # add day for sunrise tomorrow
            end
            #$log.info("Times sr #{sr.strftime("%Y/%m/%d %I:%M%p")} ss #{ss.strftime("%Y/%m/%d %I:%M%p")} ")
            if time >= sr + (s['timeoffset'].to_i * 60)
               retval = true
               #$log.info("Time match #{time} #{stime}")
            end
         when '5' # timecode 5 = before sunset
            logdata += "Schedule before sunset "
            
            if time <= sr
               ss -= 60*60*24  # subtract day for sunrise yesterday
            end
            #$log.info("Times sr #{sr.strftime("%Y/%m/%d %I:%M%p")} ss #{ss.strftime("%Y/%m/%d %I:%M%p")} ")
            if time <= ss - (s['timeoffset'].to_i * 60)
               retval = true
               #$log.info("Time match #{time} #{stime}")
            end
         when '6' # timecode 6 = after sunset
            logdata += "Schedule after sunset "
            
            if time <= sr
               ss -= 60*60*24  # subtract day for sunrise yesterday
            end
            #$log.info("Times sr #{sr.strftime("%Y/%m/%d %I:%M%p")} ss #{ss.strftime("%Y/%m/%d %I:%M%p")} ")
            if time >= ss + (s['timeoffset'].to_i * 60)
               retval = true
               #$log.info("Time match #{time} #{stime}")
            end
        end
      end
      logdata += "Matched" 
      #pp s
   end
   return retval, logdata
end

def sendcommands(id)
   query  = "SELECT * from jos_insteoncommands as c WHERE c.insteonevents_id = #{id} and c.published = 1 ORDER BY insteonevents_id, delay "
   $log.debug(query)
   cres = $mysql.query(query)
   if cres.num_rows() > 0
      clearqueue = true
      cres.each_hash() {|sd|
         if sd['commandtype'] == '0'  # insteon command
            command = "#{sd['commandprefix']}#{sd['commanddevice']}#{sd['commandflag']}#{sd['command']}"
            if clearqueue
               $controller.ClearSendQueue(sd['commanddevice'])
               clearqueue = false
			   Thread.pass
            end
            $log.info("Sending insteon command #{$controller.getcontroller(sd['commanddevice'])} #{sd['description']} #{sd['command']} delay #{sd['delay']}")
            $controller.SendPLM($controller.getcontroller(sd['commanddevice']),command,desc='Schedule command',sd['delay'].to_i)
            #$log.info("Sending insteon command #{$controller.getcontroller(sd['commanddevice'])} #{sd['description']} Status #{sd['command']} delay #{sd['delay'].to_i + 5}")
            #$controller.SendLightStatus(sd['commanddevice'],sd['delay'].to_i + 1)
         end   
         if sd['commandtype'] == '1'  # email command
            $log.info("Sending email #{sd['description']} to #{sd['email']}")
            time = Time.new
            msg  = "From: #{$emailfromname} <#{$emailfrom}>\n"
            msg += "To: <#{sd['email']}>\n"
            msg += "Subject: #{sd['description']}\n"
            msg += "\n#{sd['description']} at #{time.strftime("%Y/%m/%d %I:%M%p")}\n"
	
            begin
				Net::SMTP.start($emailserver,$emailport,$emailfromdomain,$emailuser,$emailpassword,$emaillogin) do |smtp|
					smtp.send_message msg, $emailfrom, sd['email']
					smtp.finish
				end
			rescue
				$log.error("Error sending email #{sd['description']} to #{sd['email']} error #{$!} #{$@[0]} Line: #{$.}")
			end
         end   
         if sd['commandtype'] == '2'  # directv command
            $log.info("Sending directv #{sd['description']} to #{sd['command']}")
         end   
      }
   end
end

def execute_message(m)
   time = Time.now
   if m == nil
      query  = "SELECT * from jos_insteonevents as c "
      query += "WHERE c.eventtype = 1 "
      query += "and c.published = 1"
   else
		if m.key?('Flags') and m['Flags'].length == 2
		#update average hops for the device, to be used in troubleshooting devices
			query  = "SELECT * from jos_insteondevices as c "
			query += "WHERE c.device = '#{m['From']}'"
			$log.debug(query)
			dres = $mysql.query(query)
			if dres.num_rows() > 0
				dres.each_hash() {|e|
					hops = (m['Flags'][1].hex & 3) - ((m['Flags'][1].hex & 12) / 4)
					count = e['hopscount'].to_i + 1
					avg = (((e['hopsaverage'].to_f * e['hopscount'].to_i) + hops) / count).round(6)
					hopsmax = [e['hopsaverage'].to_i,hops].max
					count = (count > 20 ? 20 : count)
					
					$devices[m['From']]['hopsaverage'] = avg
					$devices[m['From']]['hopscount'] = count
					$devices[m['From']]['hopsmax'] = hopsmax
					
					query = "UPDATE jos_insteondevices SET hopsaverage=#{avg}, hopscount=#{count}, hopsmax=#{hopsmax} "
					query += "WHERE device = '#{m['From']}'"
					$log.debug(query)
					$mysql.query(query)
				}
			end
		end
		query  = "SELECT * from jos_insteonevents as c "
		query += "WHERE c.from = '#{m['From']}' and c.to = '#{m['To']}' and '#{m['Command']}' LIKE c.command and c.eventtype = 0 "
		query += "and c.published = 1"
   end
   $log.debug(query)
   eres = $mysql.query(query)
   if eres.num_rows() > 0
      eres.each_hash() {|e|
         logdata = "Event:#{e['description']}\n"
         query = "SELECT * from jos_insteonscheduledetail as c WHERE c.insteonevents_id = #{e['id']} and c.published = 1"
         $log.debug(query)
         sdres = $mysql.query(query)
         if sdres.num_rows() > 0
            match = true
            sdres.each_hash() {|sd|
               if match
                  match,slog = checkSchedule(sd['insteonschedules_id'])
                  logdata += "   Schedule Detail:#{sd['description']}\n      #{slog}\n" if match
               end
            }
         else
            match = true
         end
         if match
            logdata.split("\n").each { |l|
               $log.info(l)
            }
            sendcommands(e['id'])
         end   
      }
   end
end


def datetest
$times = []
$times << Time.parse("2010-11-10 01:00")
$times << Time.parse("2010-11-10 02:00")
$times << Time.parse("2010-11-10 03:00")
$times << Time.parse("2010-11-10 04:00")
$times << Time.parse("2010-11-10 05:00")
$times << Time.parse("2010-11-10 06:00")
$times << Time.parse("2010-11-10 07:00")
$times << Time.parse("2010-11-10 08:00")
$times << Time.parse("2010-11-10 09:00")
$times << Time.parse("2010-11-10 10:00")
$times << Time.parse("2010-11-10 11:00")
$times << Time.parse("2010-11-10 12:00")
$times << Time.parse("2010-11-10 13:00")
$times << Time.parse("2010-11-10 14:00")
$times << Time.parse("2010-11-10 15:00")
$times << Time.parse("2010-11-10 16:00")
$times << Time.parse("2010-11-10 17:00")
$times << Time.parse("2010-11-10 18:00")
$times << Time.parse("2010-11-10 19:00")
$times << Time.parse("2010-11-10 20:00")
$times << Time.parse("2010-11-10 21:00")
$times << Time.parse("2010-11-10 22:00")
$times << Time.parse("2010-11-10 23:00")
$times << Time.parse("2010-11-10 00:00")

query = "SELECT * from jos_insteonschedules as c WHERE c.published = 1"
$log.debug(query)
sdres = $mysql.query(query)
if sdres.num_rows() > 0
   sdres.each_hash() {|sd|
      $times.each {|t|
         $log.info("Schedule #{sd['description']} Time #{t.strftime("%Y/%m/%d %I:%M%p")}")
         match=checkSchedule(sd['id'],t)
         if match
            $log.info("Matched #{sd['description']} \n")
         else
            $log.info("Missed  #{sd['description']} \n")
         end
      }
   }
end

exit
end

def repeat_every(interval)
  Thread.new do
    Thread.current["name"] = "Periodic every #{interval} seconds"
    loop do
      start_time = Time.now
	  Thread.current["time"] = start_time
      yield
      elapsed = Time.now - start_time
      sleep([interval - elapsed, 0].max)
    end
  end
end
Thread.current["name"] = "Main"
Thread.current["time"] = Time.now

$log.info('Starting PLM')
$controller = ControllerPLM.new(:heartbeat=>$heartbeat,:long=>$long,:lat=>$lat,:timezone=>$timezone)
threads = $controller.start

$log.info('Starting Periodic timer')
threads << repeat_every(15) do
	execute_message(nil)
end  

threads.each{|t|
    t.abort_on_exception = true
}
Thread.abort_on_exception = true

sleep(2)  #wait for the controller thread to get going
$controller.clearRecvQueue()

$devices = $controller.getdevices()
$controllers = $controller.getcontrollers()

$log.info("Sending IM Monitor Mode")
$controllers.each_key {|i|
    $controller.SendMonitor(i)
}
sleep(2) 

$log.info('Getting Status lights')
#get status of the lights
$devices.each_key {|device|
	case $devices[device]['category']
	when '01', '02'
		command = "0262#{device}0F1900"
		$log.info("Sending insteon status #{$controllers[$devices[device]['controller']]['name']} #{command} delay 0")
		$controller.SendPLM($devices[device]['controller'],command,desc='Insteon status',0)
	end
}

sleep(2)
$log.info('Running...')

loop do
  #$log.debug("Producer #{producer.status} Webserver #{webserver.status} Main #{Thread.main.status}")
  #Thread.list.each {|t| pp t}
  #end
  Thread.current["time"] = Time.now
  message = $controller.recvpop()
  if message
	   #$log.info("event")
        parse_buffstatus(message)
        execute_message(message)
  end
end
#}
$log.close
