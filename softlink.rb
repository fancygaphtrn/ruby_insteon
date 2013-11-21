require "awesome_print"
require "mysql"
require '/usr/src/insteon/ControllerPLM.rb'
require '/usr/src/insteon/insteonDeviceTypes.rb'
require '/usr/src/insteon/insteonConfig.rb'

#$log.level = Logger::DEBUG

$log.info('Starting...')

$mysql = Mysql::new($dbhost, $dbusername, $dbpassword, $dbtable)

$controller = ControllerPLM.new($webserver)
threads = $controller.start
threads.each{|t|
    t.abort_on_exception = true
}

sleep(2)  #wait for the controller threads to get going
$controller.clearRecvQueue()

controllers = $controller.getcontrollers()

type = ARGV[0]
controller = ARGV[1]
group = ARGV[2]
fdevice = ARGV[3]
tdevice = ARGV[4]

ap controllers
ap controller
ap group
ap fdevice
ap tdevice

if type == 'a'
    $log.info("Add #{controller} #{group} #{fdevice} #{tdevice}")
	$controller.softlink(controller, group, fdevice, tdevice) 
else
    $log.info("Delete #{controller} #{group} #{fdevice} #{tdevice}")
	$controller.softunlink(controller, group, fdevice, tdevice) 
end
