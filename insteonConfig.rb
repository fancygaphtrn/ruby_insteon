require 'thread'
require 'logger'
require '/usr/src/insteon/Sunrise.rb'
require '/usr/src/insteon/ControllerPLM.rb'
require '/usr/src/insteon/insteonDeviceTypes.rb'
require "mysql"
require 'optparse'

# OptionParser.
options = {}

optparse = OptionParser.new do|opts|
	opts.banner = "Usage: insteon.rb [options]" 
	options[:logfile] = '/usr/src/insteon/insteon.log'
	opts.on( '-l', '--logfile FILE', 'Write log to FILE. Can be STDOUT' ) do|file|
		options[:logfile] = file
	end

	options[:loglevel] = 'INFO'
	opts.on( '-L', '--loglevel LEVEL', 'Log level: FATAL|ERROR|WARN|INFO|DEBUG' ) do|level|
		options[:loglevel] = level.upcase
	end

	opts.on( '-h', '--help', 'Display this screen' ) do
		puts opts
		exit
	end
end
optparse.parse!

if options[:logfile].upcase == 'STDOUT'
	$log = Logger.new(STDOUT)
else
	$log = Logger.new(options[:logfile], 5, 10240000)
end

case options[:loglevel]
when 'FATAL'
	$log.level = Logger::FATAL
when 'ERROR'
	$log.level = Logger::ERROR
when 'WARN'
	$log.level = Logger::WARN
when 'INFO'
	$log.level = Logger::INFO
when 'DEBUG'
	$log.level = Logger::DEBUG
else
	$log.level = Logger::INFO
end

#$log.level = Logger::INFO
#$log.level = Logger::DEBUG
$log.datetime_format = "%Y-%m-%d %I:%M:%S%P"
$log.formatter = proc { |severity, datetime, progname, msg|
    if /^(.+?):(\d+)(?::in `(.*)')?/ =~ caller[4]
      file   = File.basename(Regexp.last_match[1])
      line   = Regexp.last_match[2].to_i
      method = Regexp.last_match[3]
	end
	#"#{severity} #{file}:#{line} in #{method} #{datetime.strftime("%Y-%m-%d %H:%M:%S")} #{msg}\n"
	"#{severity} #{file}:#{line} #{datetime.strftime("%Y-%m-%d %I:%M:%S%P")} #{msg}\n"
}
#Heartbeat interval in seconds
$heartbeat = 60 * 5

#Create the location for Sunrise and Sunset
$long = "36.76"
$lat = "-80.73"
$timezone = 'America/New_York'

$dbhost = 'localhost'
$dbusername = 'root'
$dbpassword = 'foofoodd'
$dbtable = 'joomla25'

$emailserver = 'mail.fancygaphtrn.com'
$emailport = 26
$emailfromdomain = 'localhost'
$emailfrom = 'htrn@fancygaphtrn.com'
$emailfromname = 'Home'
$emailuser = 'htrn+fancygaphtrn.com'
$emailpassword = '!Qwerty'
$emaillogin = 'login'    # login, plain: or cram_md5
