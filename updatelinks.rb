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

$mysql = Mysql::new($dbhost, $dbusername, $dbpassword, $dbtable)


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
	if !$exclude[controller]
		$log.info("Using controller #{controllers[controller]['name']} at #{controller}")
	
		#$log.info("Sending IM Monitor Mode")
		#$controller.SendMonitor(controller)
	
		ca = $controller.getIMinfo(controller) 
		if ca != false
			$controllerAddress = ca['Address'] 
		end
		$log.info("Controller address is #{$controllerAddress}")
	
		$log.info("Checking database relationships")
	
		query = "SELECT * from jos_insteondeviceslinks"
		$log.debug(query)
		lres = $mysql.query(query)
	
		errorfound = false
	
		lres.each_hash do |row|
			query = "SELECT id from jos_insteondevices WHERE id = '#{row['fromdeviceid']}' and published = 1"
			$log.debug(query)
			res = $mysql.query(query)
			if res.num_rows() == 0
				errorfound = true
				$log.error("Device: #{row['fromdeviceid']} error retrieving key")
			else
				$log.info("Found device: #{row['fromdeviceid']}")
			end
			toid = nil
			query = "SELECT id from jos_insteondevices WHERE id = '#{row['todeviceid']}' and published = 1"
			$log.debug(query)
			res = $mysql.query(query)
			if res.num_rows() == 0
				errorfound = true
				$log.error("Device: #{row['todeviceid']} error retrieving key")
			else
				$log.info("Found device: #{row['todeviceid']}")
			end
		end
	
		if errorfound
			$log.error("Errors found in database relationships")
			exit
		end
	
		$log.info("Checking database cross link relationships")
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
	
		errorfound = false
	
		lres.each_hash do |row|
			if !$exclude[row['fdevice']] or !$exclude[row['tdevice']]
				flags = "%02X"%(row['flags'].hex ^ "01000000".to_i(2)) # change from controller to responder or responder to controller
				query = "SELECT id from jos_insteondeviceslinks WHERE fromdeviceid = '#{row['todeviceid']}' and todeviceid = '#{row['fromdeviceid']}' and devicegroup = '#{row['devicegroup']}' and flags = '#{flags}'"
				$log.debug(query)
				res = $mysql.query(query)
				if res.num_rows() == 0
					errorfound = true
					$log.error("Cross link device: #{row['tdevice']} #{row['fdevice']} #{row['devicegroup']} #{flags} missing")
				else
					$log.info("Cross link device: #{row['tdevice']} #{row['fdevice']} #{row['devicegroup']} #{flags} found")
				end
			end
		end
	
		if errorfound
			$log.error("Errors found in database cross link relationships")
			exit
		end
	
		$log.info("Updating controller links")
		query  = "SELECT "
		query += "jfrom.device as fdevice, jfrom.description as fdescription, jfrom.friendlyname as ffriendlyname, jfrom.type as ftype, jfrom.engine as fengine, "
		query += "jto.device as tdevice, jto.description as tdescription, jto.friendlyname as tfriendlyname, jto.type as ttype, jto.engine as tengine, "
		query += "a.* "
		query += "FROM jos_insteondeviceslinks AS a "
		query += "LEFT JOIN jos_insteondevices as jfrom ON a.fromdeviceid = jfrom.id "
		query += "LEFT JOIN jos_insteondevices as jto ON a.todeviceid = jto.id " 
		query += "WHERE jfrom.device = '#{controller}' " 
		query += "ORDER BY jfrom.device " 
		$log.debug(query)
		lres = $mysql.query(query)
	
		errorfound = false
	
		lres.each_hash do |row|
	
			flags = "%02X"%(row['flags'].hex & "11111111".to_i(2))
	
			if $controller.ExistsInController(controller,flags,row['devicegroup'],row['tdevice'],row['linkdata'])
				$log.info("Controller link #{flags} #{row['devicegroup']} #{row['tdevice']} #{row['linkdata']} exists published #{row['published']}")
				if $controller.DeleteFromController(controller,flags,row['devicegroup'],row['tdevice'],row['linkdata']) 
					$log.info("Controller link #{flags} #{row['devicegroup']} #{row['tdevice']} #{row['linkdata']} deleted")
				else
					$log.error("Error deleting Controller link #{flags} #{row['devicegroup']} #{row['tdevice']} #{row['linkdata']}")
				end
			end
			if row['published'] == '1'
				if $controller.AddToController(controller,flags,row['devicegroup'],row['tdevice'],row['linkdata']) 
					$log.info("Controller link #{flags} #{row['devicegroup']} #{row['tdevice']} #{row['linkdata']} added")
				else
					$log.error("Error adding Controller link #{flags} #{row['devicegroup']} #{row['tdevice']} #{row['linkdata']}")
				end
			end
		end
	end
}   

$log.info("Updating device links")
query = "SELECT device from jos_insteondevices WHERE icontroller = 0 and published = 1 ORDER BY device"
$log.debug(query)
res = $mysql.query(query)

errorfound = false

res.each_hash do |row|
    if !$exclude[row['device']]
		print "Updating Remote device #{row['device']} database  \n"
		while !$controller.Ping($controller.getcontroller(row['device']),row['device'])
			print "Make device #{row['device']} ready then press enter or s to skip "
			STDOUT.flush 
			input = STDIN.gets.chomp
			break if input == "s"
		end
		if input != "s"
			query  = "SELECT "
			query += "jfrom.device as fdevice, jfrom.description as fdescription, jfrom.friendlyname as ffriendlyname, jfrom.type as ftype, jfrom.engine as fengine, "
			query += "jto.device as tdevice, jto.description as tdescription, jto.friendlyname as tfriendlyname, jto.type as ttype, jto.engine as tengine, "
			query += "jos_insteondeviceslinks.* "
			query += "FROM `jos_insteondeviceslinks` "
			query += "LEFT JOIN `jos_insteondevices` as jfrom ON `jos_insteondeviceslinks`.`fromdeviceid` = `jfrom`.`id` "
			query += "LEFT JOIN `jos_insteondevices` as jto ON `jos_insteondeviceslinks`.`todeviceid` = `jto`.`id` " 
			query += "WHERE jfrom.device = '#{row['device']}' "
			query += "AND jos_insteondeviceslinks.published = 1 "
			query += "ORDER BY jfrom.device " 
			$log.debug(query)
			lres = $mysql.query(query)
			
			linkrecords = []
			
			lres.each_hash do |lrow|
				linkrecords << {'To'=>lrow['tdevice'], 'Group'=>lrow['devicegroup'], 'Flags' => lrow['flags'],'Linkdata'  => lrow['linkdata']} 
			end
			sleep(1)
			$controller.remoteWriteALDB($controller.getcontroller(row['device']),row['device'],linkrecords)
			#pp linkrecords
		end
	end
end
