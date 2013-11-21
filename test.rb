require "mysql"
require '/usr/src/insteon/ControllerPLM.rb'
require '/usr/src/insteon/insteonDeviceTypes.rb'
require '/usr/src/insteon/insteonConfig.rb'

#$log.level = Logger::DEBUG

$log.info('Starting...')

$mysql = Mysql::new($dbhost, $dbusername, $dbpassword, $dbtable)

$controller = ControllerPLM.new()
threads = $controller.start
threads.each{|t|
    t.abort_on_exception = true
}

sleep(2)  #wait for the controller threads to get going

buff = '026011'
m,buff,match = $controller.parse(buff, 18)
pp m
pp buff
pp match