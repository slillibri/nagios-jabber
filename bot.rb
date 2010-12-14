#!/usr/bin/env ruby

require 'rubygems'
require 'eventmachine'
require 'xmpp4r'
require 'xmpp4r/roster'
require 'ruby-nagios/nagios/status.rb'

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
        ## Send back the roster list
        when 'roster' then 
          reply = @roster.items.keys.join("\n")
          send_msg(msg.from.to_s, "#{reply}", msg.type, msg.id)
          
        ## Schedule host downtime
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
        
        ## Schedule service downtime
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
        
        ## Acknowledge host problem
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
        
        ## List services with scheduled downtime
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
        
        ## Delete scheduled service downtime
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
          
         ## Delete scheduled host downtime
         when 'del_host_downtime' then
           begin
            nagios.parsestatus(@status_log)
            status = nagios.status
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
          
          ## List commands (incomplete)
          when 'commands' then
            reply = "roster, host_downtime, service_downtime, del_host_downtime, del_svc_downtime, commands"
            send_msg(msg.from.to_s, "#{reply}", msg.type, msg.id)
          
          ## List current host comments
          when 'hostcomments' then
            begin
              nagios.parsestatus(@status_log)
              status = nagios.status
              if status['hosts'][host].key?('hostcomments')
                comments = ''
                status['hosts'][host]['hostcomments'].each do |comment|
                  comments = comments + "[#{Time.at(comment['entry_time'].to_i).to_s}] #{comment['comment_data']}\n"
                end
                reply = "#{host} has the following comments\n#{comments}"
                send_msg(msg.from.to_s, "#{reply}", msg.type, msg.id)
              else
                send_msg(msg.from.to_s,"#{host} has no comments", msg.type, msg.id)
              end
            rescue Exception => e
              send_msg(msg.from.to_s, "#{e.message}", msg.type, msg.id)
            end
          ## List current service comments for service
          when 'servicecomments' then
            begin
              nagios.parsestatus(@status_log)
              status = nagios.status
              if status['hosts'][host].key?('servicecomments') && status['hosts'][host]['servicecomments'].key?(service)
                comments = ''
                status['hosts'][host]['servicecomments'][service].each do |comment|
                  comments = comments + "[#{Time.at(comment['entry_time'].to_i).to_s}] #{comment['comment_data']}\n"
                end
                reply = "#{service} on #{host} has the following comments\n#{comments}"
                send_msg(msg.from.to_s, "#{reply}", msg.type, msg.id)
              else
                send_msg(msg.from.to_s, "#{service} on #{host} has no comments", msg.type, msg.id)
              end
            rescue Exception => e
              send_msg(msg.from.to_s, "#{e.message}", msg.type, msg.id)
            end
          else
            send_msg(msg.from.to_s, "#{command} is not supported", msg.type, msg.id)
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
  b = Bot.new(:config => 'production.yml')
  b.run
end
::Process.detach pid
$stdout = orig_stdout
File.open('/var/run/nagios-jabber.pid', 'w') do |f|
  f.puts pid
end
