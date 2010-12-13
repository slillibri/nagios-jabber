#!/usr/bin/env ruby
require 'bot'

orig_stdout = $stdout
$stdout = File.new('/dev/null', 'w')
pid = fork do
  b = Bot.new(:botname =>  'bot@jabber.thereisnoarizona.org',:host =>  'jabber.thereisnoarizona.org',:password =>  'j4bb3rb0t!', :status_log => '/var/cache/nagios3/status.dat', :cmd_file => '/var/lib/nagios3/rw/nagios.cmd')
  b.run
end
::Process.detach pid
$stdout = orig_stdout
File.open('/var/run/nagios-jabber.pid', 'w') do |f|
  f.puts pid
end
