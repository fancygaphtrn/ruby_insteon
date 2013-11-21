#!/usr/bin/env ruby
require 'rubygems'
require '/usr/src/insteon/insteonConfig.rb'

$exclude = {}
$exclude.default =  false
$exclude['20D16C'] =  true 
$exclude['1AF8F2'] =  true 
$exclude['13DED1'] =  true 
$exclude['1411AE'] =  true 
#$exclude['14857D'] =  true 
$exclude['152A2E'] =  true 
$exclude['154AE3'] =  true 
$exclude['154DE4'] =  true 
$exclude['15BDB4'] =  true 
$exclude['15BE21'] =  true 
$exclude['232245'] =  true 
$exclude['232252'] =  true 
$exclude['141120'] =  true 
#$exclude['262C49'] =  true 

#$log.level = Logger::DEBUG

$log.info('Starting...')

$controllerAddress = '20D16C'

$mysql = Mysql::new($dbhost, $dbusername, $dbpassword, $dbtable)

$defaultcontroller = '';

$controller = ControllerPLM.new()
threads = $controller.start
threads.each{|t|
    t.priority = 2
    t.abort_on_exception = true
}

sleep(2)  #wait for the controller threads to get going
$controller.clearRecvQueue()

controllers = $controller.getcontrollers()
controllers.each_key {|controller|
    $log.info("Using controller #{controllers[controller]['name']} at #{controller}")

    $log.info("Sending IM Monitor Mode")
    $controller.SendMonitor(controller)

    $log.info("Get IM Info")
    ca = $controller.getIMinfo(controller) 
    if ca != false
        $controllerAddress = ca['Address'] 
    end
    $log.info("Controller address is #{$controllerAddress}")

    $log.info("Scanning controller")
    STDOUT.flush 

    $linkrecords = $controller.scanController(controller)

    $deviceids = {}
    $deviceids.default =  nil
    $deviceids[$controllerAddress] =  ca['Type'] 

    $engines = {}
    $engines.default =  '00'
    $engines[$controllerAddress] =  '01' 

    # get unique devices
    $devices = {}
    $linkrecords.each {|i|
        $devices[i['To']] = {'Type'  => i['Type'],'Engine'  => i['Engine']} 
    }
    $remoterecords = []
    $devices.each {|i,j|
      if !$exclude[i]
        while !$controller.Ping(controller,i)
            print "Scanning Remote device #{i} database  "
            print "Make device ready then press enter or s to skip or i to ignore "
            STDOUT.flush 
            input = STDIN.gets.chomp
            break if input == "s" or input == "i"
        end
        if input != "s" and input != "i"
            while ($engines[i] = $controller.getEngineVersion(controller,i)) == false
				$log.info("Retrying getEngineVersion Device: #{i}")
			end
			$log.info("EngineVersion Device: #{i} #{$engines[i]}")

			while ($deviceids[i] = $controller.getRequestID(controller,i)) == false
				$log.info("Retrying getRequestID Device: #{i}")
			end
			$log.info("RequestID Device: #{i} #{$deviceids[i]}")

            if $engines[i] == '01' or $engines[i] == '02'
				sleep(1)
				r = $controller.remoteSpider(controller,i)
                r.each  {|k|
					$remoterecords << k
                }
            end
		else
			if input == "s" 
				$exclude[i] =  true 
			end
        end    
      end
    }

    #pp $deviceids
    $remoterecords.each  {|j|
        $linkrecords << j
    }
    #pp $linkrecords
    $linkrecords.each {|i|
        logdata  = "From #{i['From']} "
        logdata += "Flag #{i['Flags']} "
        logdata += "Group #{i['Group']} "
        if (i['Flags'].hex & 0x40) == 0x40 # High water mark
            logdata += ",I am a Controller of "
        else
            logdata += ",I am a Responder  of "
        end
        logdata += "Device #{i['To']} "
        logdata += "Linkdata #{i['Linkdata']} #{$devicetypes[i['Linkdata'][0..3]]} "

		if !$exclude[i['From']]
			if  $deviceids[i['From']] and $engines[i['From']]
				# update jos_insteondevices from
				dtype = $deviceids[i['From']]
				query = "SELECT * from jos_insteondevices WHERE device = '#{i['From']}'"
				$log.debug(query)
				res = $mysql.query(query)
				if res.num_rows() == 0
					query = "INSERT INTO jos_insteondevices (device,friendlyname,description,type,engine,published) VALUES('#{i['From']}','#{$devicetypes[dtype[0..3]]}','#{$devicetypes[dtype[0..3]]}','#{dtype}','#{$engines[i['From']]}',0)"
					$log.debug(query)
					res = $mysql.query(query)
					$log.info("Device: #{i['From']} Type:#{dtype} inserted")
				else
					query = "UPDATE jos_insteondevices SET type='#{dtype}',description='#{$devicetypes[dtype[0..3]]}',engine='#{$engines[i['From']]}' WHERE device = '#{i['From']}'"
					$log.debug(query)
					res = $mysql.query(query)
					$log.info("Device: #{i['From']} Type:#{dtype} updated")
				end
			end
			if  $deviceids[i['To']] and $engines[i['To']]
				# update jos_insteondevices to
				dtype = $deviceids[i['To']]
				query = "SELECT * from jos_insteondevices WHERE device = '#{i['To']}'"
				$log.debug(query)
				res = $mysql.query(query)
				if res.num_rows() == 0
					query = "INSERT INTO jos_insteondevices (device,friendlyname,description,type,engine,published) VALUES('#{i['To']}','#{$devicetypes[dtype[0..3]]}','#{$devicetypes[dtype[0..3]]}','#{dtype}','#{$engines[i['To']]}',0)"
					$log.debug(query)
					res = $mysql.query(query)
					$log.info("Device: #{i['To']} Type:#{dtype} inserted")
				else
					query = "UPDATE jos_insteondevices SET type='#{dtype}',description='#{$devicetypes[dtype[0..3]]}',engine='#{$engines[i['From']]}' WHERE device = '#{i['To']}'"
					$log.debug(query)
					res = $mysql.query(query)
					$log.info("Device: #{i['To']} Type:#{dtype} updated")
				end
			end
			# get  jos_insteondevices keys
			fromid = nil
			query = "SELECT id from jos_insteondevices WHERE device = '#{i['From']}'"
			$log.debug(query)
			res = $mysql.query(query)
			if res.num_rows() == 0
				$log.error("Device: #{['From']} error retrieving key")
				fromid = nil
			else
				r = res.fetch_hash()
				fromid = r['id']
			end
			toid = nil
			query = "SELECT id from jos_insteondevices WHERE device = '#{i['To']}'"
			$log.debug(query)
			res = $mysql.query(query)
			if res.num_rows() == 0
				$log.error("Device: #{i['To']} error retrieving key")
				toid = nil
			else
				r = res.fetch_hash()
				toid = r['id']
			end
		
			# bug here update jos_insteondeviceslinks
			if toid and fromid
				query = "SELECT * from jos_insteondeviceslinks WHERE fromdeviceid = #{fromid} and todeviceid = #{toid} and devicegroup = '#{i['Group']}' and flags = '#{i['Flags']}'"
				$log.debug(query)
				res = $mysql.query(query)
				if res.num_rows() == 0
					query = "INSERT INTO jos_insteondeviceslinks (fromdeviceid, todeviceid, devicegroup,flags,linkdata,address,published) VALUES(#{fromid}, #{toid}, '#{i['Group']}', '#{i['Flags']}','#{i['Linkdata']}','#{i['Address']}',0)"
					$log.debug(query)
					res = $mysql.query(query)
					$log.info("Link: From:#{i['From']} To:#{i['To']} Group:#{i['Group']} Flags:#{i['Flags']} inserted")
				else
					r = res.fetch_hash()
					query = "UPDATE jos_insteondeviceslinks SET flags='#{i['Flags']}',linkdata='#{i['Linkdata']}',address='#{i['Address']}' WHERE id = #{r['id']}"
					$log.debug(query)
					res = $mysql.query(query)
					$log.info("Link: From:#{i['From']} To:#{i['To']} Group:#{i['Group']} Flags:#{i['Flags']} updated")
				end
				$log.info(logdata)
			end
		end
    }

    $log.info("Checking database link relationships")
    query  = "SELECT "
    query += "jfrom.device as fdevice, jfrom.description as fdescription, jfrom.friendlyname as ffriendlyname, jfrom.type as ftype, jfrom.engine as fengine, "
    query += "jto.device as tdevice, jto.description as tdescription, jto.friendlyname as tfriendlyname, jto.type as ttype, jto.engine as tengine, "
    query += "a.* "
    query += "FROM jos_insteondeviceslinks AS a "
    query += "LEFT JOIN jos_insteondevices as jfrom ON a.fromdeviceid = jfrom.id "
    query += "LEFT JOIN jos_insteondevices as jto ON a.todeviceid = jto.id " 
    #query += "WHERE  a.published = 1 " 
    query += "ORDER BY jfrom.device " 
    $log.debug(query)
    lres = $mysql.query(query)

    lres.each_hash do |row|
		if !$exclude[row['fdevice']] or !$exclude[row['tdevice']]
			flags = "%02X"%(row['flags'].hex ^ "01000000".to_i(2)) # change from controller to responder or responder to controller
			query = "SELECT id from jos_insteondeviceslinks WHERE fromdeviceid = '#{row['todeviceid']}' and todeviceid = '#{row['fromdeviceid']}' and devicegroup = '#{row['devicegroup']}'  and flags = '#{flags}'"
			$log.debug(query)
			res = $mysql.query(query)
			if res.num_rows() == 0
				#$log.error("Cross link device: #{row['tdevice']} #{row['fdevice']} #{row['devicegroup']} missing")
				flags = "%02X"%(row['flags'].hex ^ "01000000".to_i(2)) # change from controller to responder or responder to controller
				# insert missing record as unpublished
				query = "INSERT INTO jos_insteondeviceslinks (fromdeviceid, todeviceid, devicegroup,flags,linkdata,published) VALUES(#{row['todeviceid']}, #{row['fromdeviceid']}, '#{row['devicegroup']}', '#{flags}','#{row['linkdata']}',0)"
				$log.debug(query)
				ares = $mysql.query(query)
				# update half link as unpublished
				query = "UPDATE jos_insteondeviceslinks SET published=0 WHERE fromdeviceid = #{row['fromdeviceid']} and todeviceid = #{row['todeviceid']} and devicegroup = '#{row['devicegroup']}' and flags = '#{row['flags']}'"
				$log.debug(query)
				bres = $mysql.query(query)
				$log.error("Cross link device: #{row['tdevice']} #{row['fdevice']} #{row['devicegroup']} #{flags} missing, inserting")
			else
				#$log.info("Cross link device: #{row['tdevice']} #{row['fdevice']} #{row['devicegroup']} #{flags} found")
			end
		end
    end
    STDOUT.flush 
}
