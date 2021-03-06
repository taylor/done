#!/usr/bin/env ruby

ENV["BUNDLE_GEMFILE"] = "#{File.dirname(__FILE__)}/Gemfile"

require 'rubygems'
require 'fileutils'
require 'logger'
require 'tempfile'
require 'bundler'
Bundler.require

CONFIG = YAML.load_file(File.expand_path('config.yml', File.dirname(__FILE__))).with_indifferent_access

class Done < Thor

  # External editor
  EDITOR = ENV['EDITOR'] || "vim"

  # Set up log
  LOG_FILE = File.expand_path('time.log', "#{File.dirname(__FILE__)}/log")
  FileUtils.mkdir_p(File.dirname(LOG_FILE))
  LOG = Logger.new(LOG_FILE, 'weekly')
  LOG.formatter = proc {|severity, datetime, progname, msg|
    offset = msg.split.first.to_i
    if offset > 0
      datetime -= offset.minutes
      msg = msg.split[1..-1].join(' ')
    end
    "#{datetime.strftime("%F %T")} #{File.basename(`pwd`.chomp)}  #{msg}\n"
  }

  desc "report", "Daily Report"
  method_options :days_ago => 0
  def report

    if File.exists?(path = File.expand_path('freshbooks_projects.yml', File.dirname(__FILE__)))
      projects = YAML.load_file(path).with_indifferent_access
    else
      # Get client list from FreshBooks
      builder = Nokogiri::XML::Builder.new(:encoding => 'utf-8') do |xml|
        xml.request(:method => 'client.list') do
          xml.per_page 100
        end
      end
      r = Nokogiri::XML(RestClient.post(CONFIG[:url], builder.to_xml))
      r.remove_namespaces!
      clients = {}
      r.xpath("//client").each do |client|
        clients[client.at_xpath("client_id").text.to_i] = client.at_xpath("organization").text
      end
      # Get project list from FreshBooks
      builder = Nokogiri::XML::Builder.new(:encoding => 'utf-8') do |xml|
        xml.request(:method => 'project.list') do
          xml.per_page 100
        end
      end
      r = Nokogiri::XML(RestClient.post(CONFIG[:url], builder.to_xml))
      r.remove_namespaces!
      projects = {}.with_indifferent_access
      r.xpath("//project").each do |project|
        projects[project.at_xpath("project_id").text.to_i] = {
          :name => project.at_xpath("name").text,
          :client => clients[project.at_xpath("client_id").text.to_i],
        }
      end
      File.open(path, 'w') do |f|
        f << projects.to_yaml
      end
      # e.g. projects = {1 => {:client => "Client Company LLC", :name => "Create website"}}
    end

    # Parse log file, create report and open it in vim
    date = options.days_ago.days.ago
    logs = `grep '^#{date.strftime("%F")}' #{LOG_FILE}`.split("\n").sort
    directories = []
    t = Tempfile.new(%w(report .txt))
    t << "# Total: 0.0\n"
    t << "# Hours Project Comment\n"
    time = nil
    entries = []
    logs.each do |log|
      puts log
      logtime, dir, comment = /^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (\S+)  ?(.*)$/.match(log).captures
      directories << dir unless directories.include?(dir)
      logtime = Time.parse(logtime)
      time = logtime and next if time.nil?
      hours = (logtime - time) / 1.hours
      new_time = Time.parse(log[/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/])
      hours = (new_time - time) / 1.hour
      time = new_time
      next if hours.zero? || /^out$/i.match(comment.squish)
      entries << "#{hours.round(2).to_s.rjust(5)} #{dir} #{log.split[3..-1].join(' ')}\n"
    end
    entries.sort_by {|l| l.split[1]}.each {|e| t << e}
    t << "\n"
    directories.each do |dir|
      pid = CONFIG[:projects][dir]
      project = projects[pid]
      if project
        t << "# #{pid.to_s.rjust(3)} #{dir} #{project[:name]} | #{project[:client]}\n"
      else
        t << "#     #{dir} WARNING: No project set\n"
      end
    end
    t << "\n"
    projects.sort.reverse.each do |pid, project|
      t << "# #{pid.to_s.rjust(3)} #{project[:name]} | #{project[:client]}\n"
    end
    t.close
    system "vim -S #{File.expand_path(File.dirname(__FILE__))}/done.vim #{t.path}"

    # Reopen editted report, parse and send to FreshBooks
    t.open
    t.rewind
    contents = t.read.split("\n")
    contents.reject! {|l| l.squish.blank? || l =~ /^\s*#/}
    if contents.blank?
      puts "Aborting. Nothing to do."
    else
      puts "Sending time entries to freshbooks..."
      contents.each do |l|
        puts l.inspect
        hours, dir, comment = l.split(" ", 3)
        project_id = dir.to_i > 0 ? dir.to_i : CONFIG[:projects][dir]
        puts "No FreshBooks project found for #{dir}!" and next if project_id.blank?
        comment = comment.squish
        comment.gsub!(/refs #\d+/, '')
        comment.gsub!(/closes #\d+/, '')
        task_id =
          case comment
          when /RESEARCH/
            CONFIG[:tasks][:research]
          when /DEVELOPMENT/
            CONFIG[:tasks][:development]
          when /MEETING/
            CONFIG[:tasks][:meetings]
          when /UNBILLED/
            CONFIG[:tasks][:unbilled]
          when /PROBONO/
            CONFIG[:tasks][:probono]
          else
            CONFIG[:tasks][:general]
          end
        builder = Nokogiri::XML::Builder.new(:encoding => 'utf-8') do |xml|
          xml.request(:method => 'time_entry.create') do
            xml.time_entry do
              xml.project_id project_id
              xml.task_id task_id
              xml.hours hours
              xml.notes comment
              xml.date date.strftime("%F")
            end
          end
        end
        begin
          r = Nokogiri::XML(RestClient.post(CONFIG[:url], builder.to_xml))
          r.remove_namespaces!
          if r.xpath('/response').try(:attr, 'status').try(:value) == 'ok'
            puts "Sent: #{comment}"
          else
            puts r.xpath('//error').try(:text)
          end
        rescue => e
          puts "FAIL :( #{e.inspect}"
        end
      end
    end
    t.close!
  end

  desc "log [COMMENT]", "log the comment"
  def log(*comments)
    count_of_todays_logs = `grep -c '^#{Time.now.strftime("%F")}' #{LOG_FILE}`.chomp
    if count_of_todays_logs.to_i.zero?
      comments.unshift("###### #{Time.now.strftime("%A %D")} ######")
    end
    LOG.info comments.join(' ').squish
  end

  desc "gitlog", "Use the latest git log as the comment"
  def gitlog
    comment = `git log -n1 --pretty=format:%s --no-merges`
    puts comment
    log(comment)
  end

  # desc "browserlog", "Log to the active Redmine issue in Firefox"
  # def browserlog
  #   comment = `wmctrl -l | grep 'Mozilla Firefox'`
  #   a, issue_id, comment = /#(\d+): ([^-]*) -/.match(comment).to_a
  #   if issue_id && comment
  #     puts comment
  #     log("#{comment}. refs ##{issue_id}")
  #   end
  # end

  desc "editlog", "edit the current log file"
  def editlog
    system "#{EDITOR} #{LOG_FILE}"
  end
end
Done.start
