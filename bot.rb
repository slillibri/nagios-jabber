#!/usr/bin/env ruby

require 'rubygems'
require 'eventmachine'
require 'xmpp4r'
require 'xmpp4r/roster'
require 'nagios/status.rb'

class Bot
  include Jabber
  
  attr_accessor :channel, :botname, :password, :host, :roster, :client, :status_log, :nagios
  
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
    
    @client.add_message_callback {|msg|
        nagios.parsestatus(@status_log)
        host = msg.body
        action ="[#{Time.now.strftime('%s')}] SCHEDULE_HOST_DOWNTIME;${host};#{Time.now.strftime('%s')};#{Time.now.strftime('%s').to_i + 3600};0;0;3600;#{msg.from.resource};'Scheduled over IM'"
        options = {:forhost => host, :action => action}
        foo = nagios.find_services(options)
        File.open('/var/lib/nagios3/rw/nagios.cmd', 'w') do |f|
          f.puts foo
        end
        send_msg(msg.from.to_s, "#{foo}", msg.type, msg.id)        
    }
  end
  
  def run
    EM.run do
      clientSetup
    end
  end
end

#b = Bot.new(<tt>:botname =>  'bot@jabber.thereisnoarizona.org',:host =>  'jabber.thereisnoarizona.org',:password =>  'm0rph3us', :status_log => '/var/cache/nagios3/status.dat</tt>)
