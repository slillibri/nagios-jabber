#!/usr/bin/env ruby

require 'rubygems'
require 'eventmachine'
require 'xmpp4r'
require 'xmpp4r/roster'
require 'nagios/status.rb'

class Bot
  include Jabber
  
  attr_accessor :channel, :botname, :password, :host, :roster, :client, :status_log, :nagios, :cmd_file, :logger
  
  def initialize args = Hash.new
    conf = args
    if args[:config]
      conf = YAML.load(File.open(args[:config]))
    end

    ##Assign all the values we respond to from the config    
    conf.each do |attr,value|
      if self.respond_to?("#{attr}=")
        self.send("#{attr}=", value)
      end
    end
    
    @nagios = Nagios::Status.new
  end
  
  ##Send an XMPP message
  def send_msg to, text, type = :normal, id = nil
    message = Message.new(to, text).set_type(type)
    message.id = id if id
    @client.send(message)
  end 

  def clientSetup
    begin
      @client = Client.new(JID.new(@botname))
      @client.connect(@host)
      @client.auth(@password)
      @roster = Roster::Helper.new(@client)
      pres = Presence.new
      pres.priority = 5
      pres.set_type(:available)
      pres.set_status('online')
      @client.send(pres)
      @roster.wait_for_roster
      
      @client.on_exception do |ex, stream, symb|
        puts "Exception #{ex.message}"
        puts ex.backtrace.join("\n")
        exit
      end
    rescue Exception => e
      puts "Exception: #{e.message}"
      puts e.backtrace.join("\n")
    end
    
    ##TODO Make all this better.
    @client.add_message_callback {|msg|
      command,host,service = msg.body.split(/,/)
      case command
        when 'roster' then 
          reply = @roster.items.keys.join("\n")
          send_msg(msg.from.to_s, "#{reply}", msg.type, msg.id)
        when 'host_downtime' then
          begin
            action = build_action('SCHEDULE_HOST_DOWNTIME', host, msg.from.to_s, host)
            File.open(@cmd_file, 'w') do |f|
              f.puts action
            end
            send_msg(msg.from.to_s, "Scheduled downtime for #{host} for 1 hour", msg.type, msg.id)        
          rescue Exception => e
            send_msg(msg.from.to_s, "#{e.message}", msg.type, msg.id)
          end
          
        when 'service_downtime' then
          begin
            action = build_action('SCHEDULE_SVC_DOWNTIME', "#{host};#{service}", msg.from.to_s, host)
            File.open(@cmd_file, 'w') do |f|
              f.puts action
            end
            send_msg(msg.from.to_s, "Scheduled downtime for #{service} on #{host} for 1 hour", msg.type, msg.id)
          rescue Exception => e
            send_msg(msg.from.to_s, "#{e.message}", msg.type, msg.id)
          end
        when 'ack_host' then
          begin
            nagios.parsestatus(@status_log)
            start = Time.now.strftime('%s')
            action = "[#{start}] ACKNOWLEDGE_HOST_PROBLEM;#{host};1;1;1;#{msg.from.to_s};'#{host} acknowledged by #{msg.from.to_s}"
            File.open(@cmd_file, 'w') do |f|
              f.puts action
            end
            send_msg(msg.from.to_s, "Host (#{host}) acknowledged", msg.type, msg.id)
          rescue Exception => e
            send_msg(msg.from.to_s, "#{e.message}", msg.type, msg.id)
          end
        when 'services_down' then
          begin
            nagios.parsestatus(@status_log)
            reply = ''
            status = nagios.status
            status['hosts'].each do |host,statusblock|
              if statusblock.key?('servicedowntime')
                statusblock['servicedowntime'].keys.each do |service|
                  reply = reply + "#{host} #{service} is down\n"
                end
              end
            end
            send_msg(msg.from.to_s, "#{reply}", msg.type, msg.id)
          rescue Exception => e
            send_msg(msg.from.to_s, "#{e.message}", msg.type, msg.id)            
          end
        when 'del_service_downtime' then
          begin
            nagios.parsestatus(@status_log)
            status = nagios.status
            reply = ''
            start = Time.now.strftime('%s')
            downtime_id = status['hosts'][host]['servicedowntime'][service]
            action = "[#{start}] DEL_SVC_DOWNTIME;#{downtime_id}"
            File.open(@cmd_file, 'w') do |f|
              f.puts action
            end
            send_msg(msg.from.to_s, "Canceled Downtime for #{host} - #{service}", msg.type, msg.id)
          rescue Exception => e
            send_msg(msg.from.to_s, "#{e.message}", msg.type, msg.id)
          end
         when 'del_host_downtime' then
           begin
            nagios.parsestatus(@status_log)
            start = Time.now.strftime('%s')
            downtime_id = status['hosts'][host]['hostdowntime']
            action = "[#{start}] DEL_HOST_DOWNTIME;#{downtime_id}"
            File.open(@cmd_file, 'w') do |f|
              f.puts action              
            end
            send_msg(msg.from.to_s, "Canceled Downtime for #{host}", msg.type, msg.id)
           rescue Exception => e
            send_msg(msg.from.to_s, "#{e.message}", msg.type, msg.id)
           end
          when 'commands' then
            reply = "roster, host_downtime, service_downtime, del_host_downtime, del_svc_downtime, commands"
            send_msg(msg.from.to_s, "#{reply}", msg.type, msg.id)
      end
    }
  end
  
  def build_action(action, options, from, host)
    begin
      nagios.parsestatus(@status_log)
      start = Time.now.strftime('%s')
      dend  = start.to_i + 3600
      action = "[#{start}] #{action};#{options};#{start};#{dend};0;0;3600;#{from};'Scheduled over IM by #{from}'"
      reply = nagios.find_services(:forhost => host, :action => action)
      return reply
    rescue
      throw Exception.new('Unable to build action')
    end
  end
  
  def run
    EM.run do
      clientSetup
    end
  end
end

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
