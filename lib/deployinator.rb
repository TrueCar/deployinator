require 'deployinator/version'
# = Deployinator
#
# This is the main entry point for all things in the Deployination.
module Deployinator

  # = Config settings
  class << self
    # File to log to
    attr_accessor :log_file

    # Your company domain name
    attr_accessor :domain

    # Hostname where deployinator runs
    attr_accessor :hostname

    # Default username for passwordless ssh
    attr_accessor :default_user

    # Default github_host
    attr_accessor :github_host

    # Bug or issue tracker - proc that takes the issue id as an argument
    # ex: Deployinator.issue_tracker = proc {|issue| "http://foo/browse/#{issue}"}
    attr_accessor :issue_tracker

    # a hash for context specifics settings (test,dev,production) of deployinator itself
    attr_accessor :app_context

    # Your install root
    attr_accessor :root_dir

    # Global git info
    attr_accessor :git_info

    # Git info per stack
    attr_accessor :git_info_for_stack

    # Deploy Host
    attr_accessor :deploy_host

    # Timing Log path
    attr_accessor :timing_log_path

    # Log path
    attr_accessor :log_path

    # Template for streamed logs
    attr_accessor :stream_template_file

    attr_accessor :git_sha_length

    attr_accessor :global_plugins

    attr_accessor :stack_plugins

    attr_accessor :stack_tailer_port

    attr_accessor :admin_groups
    @admin_groups = []

    # the controller class. defaults to Deployinator::Controller
    # if you override this it should be a subclass of Deployinator::Controller
    attr_accessor :deploy_controller

    def initialize
      @stack_plugins = {}
      @global_plugins = []
      @admin_groups = []
    end

    # Base root path
    # Takes an optional argument of a string or array and returns the path(s)
    # From the root of deployinator
    def root(path = nil)
      base = Deployinator.root_dir
      path ? File.join(base, path) : base
    end

    # is a log file defined?
    def log_file?
      log_file
    end

    # Running environment for deployinator
    # This is taken from RACK_ENV or RAILS_ENV
    # *note* this is different from deployinator's concept of stacks/environments
    def env
      ENV["RACK_ENV"] || ENV["RAILS_ENV"] || "development"
    end

    # Gets all the stack files in the stack directory
    def get_stack_files
      Dir[Deployinator.root(["stacks", "*.rb"])]
    end

    # Gets all the stack names without the .rb extension
    def get_stacks
      self.get_stack_files.sort.map do |file|
        File.basename(file, ".rb")
      end
    end
  end
end

Deployinator.root_dir = Dir.pwd
Deployinator.app_context = {}
Deployinator.admin_groups = []
Deployinator.global_plugins = []
Deployinator.log_file = Deployinator.root(["log", "development.log"])
Deployinator.log_path = Deployinator.root(["log", "deployinator.log"])
Deployinator.timing_log_path = Deployinator.root(["log", "deployinator-timing.log"])
Deployinator.git_sha_length = "10"
Deployinator.default_user = `whoami`
Deployinator.stack_tailer_port = 7778
Deployinator.git_info = {
  :github_host => 'github.com',
  :github_host_http_proto => 'https',
}
Deployinator.github_host = 'github.com'
Deployinator.app_context['context'] = 'dev'
Deployinator.stream_template_file = "#{File.dirname(__FILE__)}/deployinator/templates/stream.mustache"
