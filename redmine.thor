require 'ostruct'
require 'active_resource'
require 'ruby-debug'

class Issue < ActiveResource::Base

  def self.config
    @config ||= OpenStruct.new(YAML.load_file(File.expand_path("~/.redmine")))
  rescue Errno::ENOENT
    say "You need to create the file .redmine in your home with your username, password and url"
    exit(1)
  end

  self.site = config.url
  self.user = config.username
  self.password = config.password
end

class Redmine < Thor

  desc "list", "List all issues for the user"
  method_option :assigned_to, :default => "me",  :aliases => "-at", :desc => "id of person the ticket is assigned to"
  method_option :all,         :type => :boolean, :aliases => "-a",  :desc => "list all tickets"
  def list
    params = {}

    unless options.all
      params[:assigned_to_id] = options.assigned_to
    end

    collection = Issue.all(:params => params)

    issues = collection.collect { |issue| [link_to_issue(issue.id), issue.subject, issue.status.name] }

    if issues.any?
      issues.insert(0, ["URL", "Subject", "Status"])
      print_table(issues)
    end
  end

  no_tasks do
    def link_to_issue(id)
      "#{Issue.config.url}/issues/#{id}"
    end
  end
end
