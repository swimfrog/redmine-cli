require 'thor'
require 'redmine-cli/field'
require 'redmine-cli/config'
require 'redmine-cli/resources'
require 'redmine-cli/generators/install'
require 'rubygems'
require 'ruby-debug'
require 'interactive_editor'
require 'yaml'
require 'pp'

$KCODE='u'

module Redmine
  module Cli
    class CLI < Thor

      desc "list", "List all issues for the user"
      method_option :assigned_to, :aliases => "-a",  :desc => "id or user name of person the ticket is assigned to"
      method_option :status,      :aliases => "-s",  :desc => "id or name of status for ticket"
      method_option :project,     :aliases => "-p",  :desc => "project id"
      method_option :version,     :aliases => "-v",  :desc => "the target version"
      method_option :query,       :aliases => "-q",  :desc => "list issues according to a saved custom query"
      method_option :tracker,     :aliases => "-T",  :desc => "id or name of tracker for ticket"
      method_option :std_output,  :aliases => "-o",  :desc => "output a space-delimited list of ticket numbers that match the specified criteria (useful when piped to \"update\" command", :type => :boolean
      method_option :sort,        :aliases => "-S",  :desc => "sort by the specified column"

      def list
        params = {}

        params[:assigned_to_id] = map_user(options.assigned_to) if options.assigned_to
        params[:status_id] = map_status(options.status) if options.status
        params[:tracker_id] = map_tracker(options.tracker) if options.tracker
        params[:project_id] = map_project(options.project) if options.project
        params[:query_id] = map_query(options.query) if options.query
        params[:sort] = options[:sort] if options[:sort]

        collection = Issue.fetch_all(params)

        selected_fields = Redmine::Cli::config.list_fields || ["url", "subject", "status"]

        unless options.std_output
          # collection.sort! {|i,j| i.status.id <=> j.status.id }
          collection.sort! {|i,j| i.priority.id <=> j.priority.id }
          
          # Retrieve the list of issue fields in selected_fields
          issues = collection.collect { |issue|
            selected_fields.collect {|key|

              assignee = ""
              assignee = issue.assigned_to.name if issue.respond_to?(:assigned_to)
              version = issue.fixed_version.name if issue.respond_to?(:fixed_version)
  
              # Hack, because I don't feel like spending much time on this
              if options.version
                next unless version == options.version
              end

              # This section tries to fill in the field using various methods. First, we try to reference it as a built-in field for which we have a title, ref, and display method.
              # If we don't have that, then we try to reference it as an attribute of the issue object.
              # If at any point we try to reference something that gives us an IndexError, we assume that that is not a native field, and we try to look through the custom fields to find it.
              # Finally, if that fails, we let the value simply be "".
              #
              val = ""
  
              begin
                # If this is a built-in field for which we have a title, ref, and display method, use that.
                field = fields.fetch(key)
                if field.display
                  value = issue.attributes.fetch(field.ref)
                  val = field.display.call(value)
                else
                  f = fields.fetch(key).ref
                  val = issue.attributes.fetch(f)
                end
              rescue IndexError
                # Otherwise, let's look for a custom field by that name.
                if issue.attributes[:custom_fields].present?
                  issue.attributes[:custom_fields].collect { | field | 
                    if field.attributes.fetch("name") == key
                      val = field.attributes.fetch("value")
                    end
                  }
                end
                ""

              end

              val
            }
            #STDERR.puts "Debug: Issue #{issue.id} data:\n#{issue.to_yaml()}".brown.brown.brown
          }

          if issues.any?
            issues.insert(0, selected_fields.collect {| key |
              begin
                fields.fetch(key).title
              rescue IndexError
                key
              end
            })

            print_table(issues)
            say "#{collection.count} issues - #{link_to_project(params[:project_id])}", :yellow
          end
          
          # Clean up after ourselves
          issues.compact!
        else
          say collection.collect(&:id).join(" ")
        end
      end

      desc "projects", "Lists all projects"
      def projects
        projects = Project.fetch_all.sort {|i,j| i.name <=> j.name}.collect { |project| [ project.id, project.identifier, project.name ] }
        if projects.any?
          projects.insert(0, ["Id", "Key", "Name"])
          print_table(projects)
          say "#{projects.count-1} projects - #{link_to_project}", :yellow
        end
      end

      method_option :status,      :type => :boolean, :aliases => "-s",  :desc => "id or name of status for ticket"
      method_option :priority,    :type => :boolean, :aliases => "-p",  :desc => "id or name of priority for ticket"
      method_option :tracker,     :type => :boolean, :aliases => "-T",  :desc => "id or name of tracker for ticket"
      method_option :subject,     :type => :boolean, :aliases => "-t",  :desc => "subject for ticket (title)"
      method_option :description, :type => :boolean, :aliases => "-d",  :desc => "description for ticket"
      method_option :assigned_to, :type => :boolean, :aliases => "-a",  :desc => "id or user name of person the ticket is assigned to"
      method_option :notes,       :type => :boolean, :aliases => "-n",  :desc => "add a note to the Redmine ticket (interactively)"
      desc "edit [OPTIONS] TICKET", "Interactively edit the fields of an issue"
      def edit(ticket)
        issue = Issue.find(ticket)

        if options.empty?
          say "You must specify at least one field to edit", :red
          exit
        end
        
        data = {}
        options.each { | key, val |
          # Set the initial value to one of:
          #   The direct string representation of the issue's key
          #   The value of the issue's key's "name" member
          #   A multi-line string initialized to a message appropriate to the value (most useful for "notes" and "description")
          initialval = issue.attributes.has_key?(key) && ! issue.attributes[key].nil? ? case issue.attributes[key]
            when String then issue.attributes[key].to_s
            else issue.attributes[key].name.to_s
          end : "Enter your #{key} here.\n\n"

          data[key] = initialval.clone.ed

          if data[key] == initialval
            # If the user didn't actually edit the field, then don't submit it for update.
            say "You did not change the value, so the edit to #{key} was ignored.", :red 
            data.delete(key)
          end
        }

        unless data.empty?
          update_ticket(ticket, data.with_indifferent_access)
        else
          say "There was no new data to submit, so #{ticket} was not updated.", :red
        end


      rescue ActiveResource::ResourceNotFound
        say "No ticket with number: #{ticket}", :red
      end

      desc "show TICKET", "Display information of a ticket"
      def show(ticket)
        params = {}
        params[:params] = {:include => "journals,changesets"}

        issue = Issue.find(ticket, params)

        display_issue(issue)
      rescue ActiveResource::ResourceNotFound
        say "No ticket with number: #{ticket}", :red
      end

      method_option :assigned_to, :aliases => "-a",  :desc => "id or user name of person the ticket is assigned to"
      method_option :status,      :aliases => "-s",  :desc => "id or name of status for ticket"
      method_option :project,     :aliases => "-p", :desc => "project for the ticket"
      method_option :tracker,     :aliases => "-T", :desc => "tracker for the ticket"
      desc "new SUBJECT [DESCRIPTION]", "Create a new ticket"
      def new(subject, description="")
        params =
          Thor::CoreExt::HashWithIndifferentAccess.new(:subject => subject,
                                                       :description => description,
                                                       :project => Redmine::Cli::config.default_project_id)
        params.merge!(options)

        unless params.project
          raise "No default project specified"
        end

        issue = Issue.create(ticket_attributes(params))

        say "Created ticket: #{link_to_issue(issue.id)}", :green
      rescue ActiveResource::ResourceNotFound
        say "Could not create ticket with: #{options.inspect}", :red
      rescue RuntimeError => e
        say e.message, :red
      end

      method_option :tickets,     :aliases => "-l",  :desc => "list of tickets", :type => :array
      method_option :status,      :aliases => "-s",  :desc => "id or name of status for ticket"
      method_option :priority,    :aliases => "-p",  :desc => "id or name of priority for ticket"
      method_option :tracker,     :aliases => "-T",  :desc => "id or name of tracker for ticket"
      method_option :subject,     :aliases => "-t",  :desc => "subject for ticket (title)"
      method_option :description, :aliases => "-d",  :desc => "description for ticket"
      method_option :assigned_to, :aliases => "-a",  :desc => "id or user name of person the ticket is assigned to"
      method_option :notes,       :aliases => "-n",  :desc => "an optional note about this update"
      desc "update [TICKETS]", "Update tickets"
      def update(*tickets)
        tickets = options.tickets if tickets.blank? && options.tickets.present?

        if tickets.empty?
          say "No tickets to update", :red
          exit 1
        end

        tickets.collect { |ticket| Thread.new { update_ticket(ticket, options) } }.each(&:join)
      end

      desc "install [URL] [USERNAME] [FIELDS]", "Generates a default configuration file"
      method_option :test, :type => :boolean
      def install(url = "localhost:3000", username = "", fieldcsv="")
        url = "http://#{url}" unless url =~ /\Ahttp/

        if username.blank?
          username = ask("Username?")
        end

        password = ask_password("Password?")

        if fieldcsv.blank?
          fieldcsv = ask("\nWhat fields should be displayed in \"redmine list\"?\n\nPossible values are: [" + fields.keys.join(", ") + "]\n\nEnter a list of comma-separated fields: ")
        end

        list_fields = fieldcsv.split(",")

        arguments = [url, username, password, list_fields]
        arguments.concat(["--test"]) if options.test

        Redmine::Cli::Generators::Install.start(arguments)
      end

      no_tasks do

        # Prints a table.
        #
        # ==== Parameters
        # Array[Array[String, String, ...]]
        #
        # ==== Options
        # indent<Integer>:: Indent the first column by indent value.
        # colwidth<Integer>:: Force the first column to colwidth spaces wide.
        #
        def print_table(array, options = {}) # rubocop:disable MethodLength
          return if array.empty?
  
          formats, indent, colwidth = [], options[:indent].to_i, options[:colwidth]
          options[:truncate] = terminal_width if options[:truncate] == true
  
          formats << "%-#{colwidth + 2}s" if colwidth
          start = colwidth ? 1 : 0
  
          colcount = array.max { |a, b| a.size <=> b.size }.size
  
          maximas = []
  
          start.upto(colcount - 1) do |index|
            maxima = array.map { |row|
              skip = false
              rowlen = row[index].to_s.chars.collect { | char |
                # Deal with ASCII escape sequences (skip them), also acknowledge that
                # a char might consist of more than one byte in the case of unicode characters.
                bytes = char.bytes.to_a
                if bytes[0] < 32
                  skip = true
                end
                if bytes[0] == 109 && skip == true
                  skip = false
                  0
                  next
                end
                #puts "#{bytes.to_s} #{char} skip=#{skip}"
                # FIXME: Unicode characters in most terminal fonts take up somewhere
                # between 1 and 2 columns. So this isn't exact. (But it's better than nothing)
                skip == true ? 0 : char.bytes.to_a.length > 1 ? 2 : 1
              }.compact.reduce(:+)
              row[index].present? ? rowlen : 0
            }.max
            maximas << maxima
            if index == colcount - 1
              # Don't output 2 trailing spaces when printing the last column
              formats << '%-s'
            else
              formats << "%-#{maxima + 2}s"
            end
          end
  
          formats[0] = formats[0].insert(0, ' ' * indent)
          formats << '%s'

          array.each do |row|
            sentence = ''
  
            row.each_with_index do |column, index|
              maxima = maximas[index]
  
              if column.is_a?(Numeric)
                if index == row.size - 1
                  # Don't output 2 trailing spaces when printing the last column
                  f = "%#{maxima}s"
                else
                  f = "%#{maxima}s "
                end
              else
                f = formats[index]
              end
              sentence << f % column.to_s
            end
  
            sentence = truncate(sentence, options[:truncate]) if options[:truncate]
            puts sentence
          end
        end

        def link_to_issue(id)
          "#{Redmine::Cli::config.url}/issues/#{id}"
        end

        def link_to_project(name = nil)
          if name
            "#{Redmine::Cli::config.url}/projects/#{name}/issues"
          else
            "#{Redmine::Cli::config.url}"
          end
        end

        def status_name(status)
           status.name
        end

        def ticket_attributes(options)
          attributes = {}

          attributes[:subject]        = options["subject"]               if options["subject"].present?
          attributes[:description]    = options["description"]           if options["description"].present?
          attributes[:project_id]     = map_project(options["project"])  if options["project"].present?
          attributes[:assigned_to_id] = map_user(options["assigned_to"]) if options["assigned_to"].present?
          attributes[:status_id]      = map_status(options["status"])    if options["status"].present?
          attributes[:priority_id]    = map_priority(options["priority"])if options["priority"].present?
          attributes[:tracker_id]     = map_tracker(options["tracker"])  if options["tracker"].present?
          attributes[:notes]          = options["notes"]                 if options["notes"].present?

          attributes
        end

        def display_issue(issue)
          shell.print_wrapped "#{issue.project.name} ##{issue.id} - #{link_to_issue(issue.id)} - #{issue.status.name}"
          shell.print_wrapped "Priority: #{issue.priority.name}"
          if issue.attributes[:assigned_to].present?
            shell.print_wrapped "Assigned To: #{issue.attributes[:assigned_to].name}"
          end
          shell.print_wrapped "Subject: #{issue.subject}"
          shell.print_wrapped "Tracker: #{issue.tracker.name}"
          shell.print_wrapped issue.description || "", :indent => 2
          if issue.journals.any?
            issue.journals.each do |journal|
              details = journal.details.collect do |detail|
                unless detail.name == "description"
                  "#{detail.name}: #{detail.old_value} => #{detail.new_value}"
                else
                  # Multi-line descriptions can make output unreadable.
                  "#{detail.name} updated"
                end
              end
              shell.print_wrapped "Updated by #{journal.user.name} on #{journal.created_on} (#{details})"
              shell.print_wrapped "#{journal.notes}\n\n###".bold, :indent => 2 if journal.notes.present?
            end
          end
        end

        def map_user(user_name)
          get_mapping(:user_mappings, user_name)
        end

        def map_status(status_name)
          get_mapping(:status_mappings, status_name)
        end

        def map_priority(priority_name)
          result = get_mapping(:priority_mappings, priority_name)
          if Redmine::Cli::config["colorize"]
            case result
              # This is sort of a hack... ANSI sequences make it hard to figure out column lengths.
              # So we make all fields the same length and with the same number of unprintable ansi
              # sequence characters.
  
              when "Low" then       "Low      ".blue.blue.blue
              when "Normal" then    "Normal   ".green.green.green
              when "High" then      "High     ".red.red.red
              when "Urgent" then    "Urgent   ".bold.red.red
              when "Immediate" then "Immediate".blink.bold.red
              else result[0...9]
            end
          else
            result
          end
        end

        def map_project(project_name)
          get_mapping(:project_mappings, project_name)
        end

        def map_query(query_name)
          get_mapping(:query_mappings, query_name)
        end

        def update_mapping_cache
          unless Redmine::Cli::config["disable_caching"]
            say 'Updating mapping cache...', :yellow
            # TODO: Updating user mapping requries Redmine 1.1+
            # TODO: Retrieving user mapping requires admin privileges in Redmine
            users = []
            begin
              users = User.fetch_all.collect { |user| [ user.login, user.id ] }
            rescue Exception => e
              say "Failed to fetch users: #{e}", :red
            end
            projects = Project.fetch_all.collect { |project| [ project.identifier, project.id ] }
            queries = Query.fetch_all.collect { |query|
                    [ query.name, query.id ]
            }
  
            priorities = {}
            status = {}
            Issue.fetch_all.each do |issue|
                priorities[issue.priority.name] = issue.priority.id if issue.priority
                status[issue.status.name] = issue.status.id if issue.status
            end
          
            # TODO: Need to determine where to place cache file based on
            #       config file location.
            File.open(File.expand_path('~/.redmine_cache'), 'w') do |out|
              YAML.dump({
                :user_mappings => Hash[users],
                :project_mappings => Hash[projects],
                :priority_mappings => priorities,
                :status_mappings => status,
                :query_mappings => Hash[queries],
              }, out)
            end
          end
        end

        def map_tracker(tracker_name)
          get_mapping(:tracker_mappings, tracker_name)
        end

        def map_version(fixed_version)
          get_mapping(:version_mappings, fixed_version)
        end

        def get_mapping(mapping, value)
          begin
            return value if value.to_i != 0
          rescue NoMethodError
            return value.attributes.fetch("name") if value.id.to_i != 0
          end
          
          if Redmine::Cli::config[mapping].nil? || (mapped = Redmine::Cli::config[mapping][value]).nil?
            if !(mapped = get_mapping_from_cache(mapping, value))
              update_mapping_cache

              if !(mapped = get_mapping_from_cache(mapping, value))
                say "No #{mapping} for #{value}", :red
                exit 1
              end
            end
          end

          return mapped
        end

        def get_mapping_from_cache(mapping, value)
          begin
            if Redmine::Cli::cache[mapping].nil? || (mapped = Redmine::Cli::cache[mapping][value]).nil?
              return false
            end
            return mapped
          rescue
            # We need to recover here from any error that could happen
            # in case the cache is corrupted.
            return false
          end
        end

        def update_ticket(ticket, options)
          issue = Issue.find(ticket)
          params = ticket_attributes(options)

          if issue.update_attributes(params)
            params[:params] = {:include => "journals,changesets"}
            issue = Issue.find(ticket, params)
            say "Updated: #{ticket}. Options: #{params.inspect}", :green
            display_issue(issue)
          else
            say "Could not update ticket with: #{params.inspect}", :red
          end
        rescue ActiveResource::ResourceNotFound
          say "Could not find ticket: #{ticket}", :red
        end

        def ask_password(prompt)
          system "stty -echo"
          password = ask(prompt)
          system "stty echo"
          password
        end

        def fields()
          # This is a collection of built-in Redmine fields, the key by which they can be accessed, and a wrapper
          # method that is used to display their value. Pseudo-fields can be added that use different wrapper
          # methods to give the user flexibility over their output (see url vs. id)
          return {
            "url" => Field.new("URL", "id", method(:link_to_issue)),
            "id" => Field.new("ID#", "id"),
            "subject" => Field.new("Subject", "subject"),
            "status" => Field.new("Status", "status", method(:status_name)),
            "start_date" => Field.new("Start", "start_date"),
            "estimated_hours" => Field.new("Estd", "estimated_hours"),
            "tracker" => Field.new("Type", "tracker", method(:map_tracker)),
            "priority" => Field.new("Priority", "priority", method(:map_priority)),
            "description" => Field.new("Description", "description"),
            "assigned_to" => Field.new("Assigned To", "assigned_to", method(:map_user)),
            "project" => Field.new("Project", "project", method(:map_user)),
            "author" => Field.new("Author", "author", method(:map_user)),
            "done_ratio" => Field.new("% Done", "done_ratio"),
            "due_date" => Field.new("Due On", "due_date"),
            "created_on" => Field.new("Created On", "created_on"),
            "updated_on" => Field.new("Updated On", "updated_on"),
            "version" => Field.new("Version", "fixed_version", method(:map_version)),
          }
        end

        def default_parameters
          {:limit => 100}
        end
      end
    end
  end
end

class String
  def black;          "\033[30m#{self}\033[0m" end
  def red;            "\033[31m#{self}\033[0m" end
  def green;          "\033[32m#{self}\033[0m" end
  def brown;          "\033[33m#{self}\033[0m" end
  def blue;           "\033[34m#{self}\033[0m" end
  def magenta;        "\033[35m#{self}\033[0m" end
  def cyan;           "\033[36m#{self}\033[0m" end
  def gray;           "\033[37m#{self}\033[0m" end
  def bg_black;       "\033[40m#{self}\0330m"  end
  def bg_red;         "\033[41m#{self}\033[0m" end
  def bg_green;       "\033[42m#{self}\033[0m" end
  def bg_brown;       "\033[43m#{self}\033[0m" end
  def bg_blue;        "\033[44m#{self}\033[0m" end
  def bg_magenta;     "\033[45m#{self}\033[0m" end
  def bg_cyan;        "\033[46m#{self}\033[0m" end
  def bg_gray;        "\033[47m#{self}\033[0m" end
  def bold;           "\033[1m#{self}\033[22m" end
  def blink;          "\033[5m#{self}\033[22m" end
  def reverse_color;  "\033[7m#{self}\033[27m" end
end
