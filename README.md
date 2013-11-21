ruby_insteon
============

Insteon home automation using ruby

My home automation is based on a ruby code that runs as a daemon within Linux.  Originally, it was on an old PC running CentOS, but currently runs on a Raspberry pi.

The heart of the system is a set of Ruby scripts that run as a background task/daemon that receives events from the Insteon controllers, matches events to the configuration in a Mysql, the issues commands based on schedules.

An event is:

	Any Insteon message, such as a motion sensor on, light off, etc.
	A timed event, such as at 11:00pm

A schedule is one of the following with optional offset and days of the week.  There can multiple of these.

	Before Time
	After Time
	At Time
	Before Sunrise
	After Sunrise
	Before Sunset
	After Sunset

A command is:

  Any Insteon message, such as turn light off in 5 minutes
  
  An email, usefull when you are away and a motion sensor is turned on
  
  A command to a Directv DVR (experimental)

Using these you can configure the system with sequences such as:

Timed Event All lights off At 11pm

  Insteon Command Bathroom Light off Delay 0
  
  Insteon Command Outside backporch Light off Delay 0
  
  Insteon Command Shop porch Light off Delay 0
  
  Insteon Command Tod's Room Table Desk light off Delay 0
  
  Insteon Command Tod's Room Table Light off Delay 0

Insteon Event Kitchen motion on 30 min after Sunset and Before sunrise

  Insteon Command Bathroom Light on Delay 0

Other Ruby utilities include:

spider.rb  will scan the Insteon network looking for devices and their link databases information, storing in the MySQL database
	
updatelinks.rb will update Insteon network link databases information, using information from the MySQL database
	
To configure the database, provide reporting and monitoring,  I developed an administrative component for the Joomla CMS
