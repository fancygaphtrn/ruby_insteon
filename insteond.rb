#!/usr/bin/env ruby
require 'rubygems'
require 'daemons'
 
file = '/usr/src/insteon/insteon.rb'
options = {
    :app_name   => "insteond",
    :monitor    => true,
    #:log_output => true,
	:dir_mode   => :script
}

Daemons.run(file,options)
