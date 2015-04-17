require 'enumerator'
require 'date'
require 'octokit'

module Deployinator
  module Helpers
    # Public: module containing helper methods for interacting with git
    # repositories and extracting information from them.
    module GitHelpers

      Octokit.configure do |c|
        c.api_endpoint = Deployinator.git_info[:github_api_endpoint]
        c.web_endpoint = Deployinator.git_info[:github_web_endpoint]
      end

      @@octokit = Octokit::Client.new(:login => Deployinator.git_info[:github_login],
                                      :password => Deployinator.git_info[:github_password])

      # Where we cache the current head rev. stack name wil be appended
      @@rev_head_cache = "/tmp/rev_head_cache"

      # How many seconds the head rev cache is good for
      @@rev_head_cache_ttl = 15

      def build_git_cmd(cmd, extra_cmd)
        unless extra_cmd.nil? or extra_cmd.empty?
          "#{extra_cmd} '#{cmd}'"
        else
          cmd
        end
      end

      # Public: method to get the short rev of a git commit and create a
      # version tag from it. The tag is then dumped into a version text file.
      #
      # stack       - String representing the stack, which determines where the
      #               version file should be located
      # version_dir - String (or Array of Strings) representing the
      #               directories to contain the version file
      # extra_cmd   - String representing an additional command to prepend to
      #               the version echo command (default: "")
      # path        - String containing the base path where the version file is
      #               located (default: nil)
      # rev         - String containing the rev to parse for the short SHA id
      #               (default: "HEAD")
      #
      #
      # Returns STDOUT of the echo command
      def git_bump_version(stack, version_dir, extra_cmd="", path=nil, rev="HEAD", tee_cmd="tee")
        unless version_dir.kind_of?(Array)
          version_dir = [version_dir]
        end

        ts = Time.now.strftime("%Y%m%d-%H%M%S-%Z")

        path ||= git_checkout_path(checkout_root, stack)

        cmd = "cd #{path} && git rev-parse --short=#{Deployinator.git_sha_length} #{rev}"
        cmd = build_git_cmd(cmd, extra_cmd)
        sha1 = run_cmd(cmd)[:stdout]

        version = "#{sha1.chomp}-#{ts}"

        fullpaths = ""
        version_dir.each do |dir|
          fullpath = File.join(dir, "version.txt")
          fullpaths << fullpath + " "
        end

        log_and_stream "Setting #{fullpaths} to #{version}"

        cmd = "cd #{path} && echo #{version} | #{tee_cmd} #{fullpaths}"
        cmd = build_git_cmd(cmd, extra_cmd)
        run_cmd cmd

        return version
      end

      # Public: git helper method to get the path to checkout the git repo to
      #
      # checkout_root - the directory base for the repo location
      # stack       - String representing the stack, which determines where the
      #               version file should be located
      #
      # Returns path to checkout git repo to
      def git_checkout_path(checkout_root, stack)
        if (git_info_for_stack[stack.intern].has_key?(:checkout_dir))
          dir = git_info_for_stack[stack.intern][:checkout_dir].to_s
        else
          dir = stack.to_s
        end
        File.join(checkout_root, dir)
      end

      # Public: git helper method to bring a local repo up to date with the
      # remote
      #
      # stack     - the stack we want to update the repo for
      # extra_cmd - a command that can be prepended before the actual command
      # path      - the path to the repo. This is also passed to the block as
      #             an argument if one is provided
      # branch    - the branch to checkout after the fetch
      #
      # Returns nothing
      def git_freshen_clone(stack, extra_cmd="", path=nil, branch="master")
        path ||= git_checkout_path(checkout_root, stack)
        cmd = "cd #{path} && git fetch --quiet origin +refs/heads/#{branch}:refs/remotes/origin/#{branch} && git reset --hard origin/#{branch} 2>&1"
        cmd = build_git_cmd(cmd, extra_cmd)
        run_cmd cmd
        yield "#{path}" if block_given?
      end

      # Public: wrapper function which can be used to clone a non-existing repo
      # or freshen an existing one. It tests if the path exists and fetches
      # remotes if that's the case. Otherwise the repo is checked out at the
      # given path.
      #
      # Examples:
      #   git_freshen_or_clone("web", etsy_qa, "/var/etsy/", "master")
      #
      # stack         - the stack to refresh or clone the repo for
      # extra_cmd     - cmd to prepend before the actual command
      # checkout_root - the directory base for the repo location
      # branch        - the branch the repo should be on (currently only used
      #                 when the repo is refreshed). (default: master)
      # read_write    - boolean; True means clone the repo read/write
      #
      # Returns stdout of the respective git command.
      def git_freshen_or_clone(stack, extra_cmd, checkout_root, branch="master", read_write=false, protocol="git")
        path = git_checkout_path(checkout_root, stack)
        is_git = is_git_repo(path, extra_cmd)
        if is_git == :true
          log_and_stream "</br>Refreshing repo #{stack} at #{path}</br>"
          git_freshen_clone(stack, extra_cmd, path, branch)
        elsif is_git == :missing
          log_and_stream "</br>Cloning branch #{branch} of #{stack} repo into #{path}</br>"
          git_clone(stack, git_url(stack, protocol, read_write), extra_cmd, checkout_root, branch)
        else
          log_and_stream "</br><span class=\"stderr\">The path for #{stack} at #{path} exists but is not a git repo.</span></br>"
        end
      end

      # Public: Filters a range of commits and either returns all commit shas that
      # only include the filter_file, or the inverse list of shas.
      #
      # stack         - the stack to refresh or clone the repo for
      # extra_cmd     - cmd to prepend before the actual command
      # old_rev       - the git sha representing an older rev.
      # new_rev       - the git sha representing a newer rev.
      # path          - optional parameter to overide the path to the git repo.
      # filter_files  - filepaths relative to the root of the git repo to use as the filter
      # including     - Should the returned list of filters include the filter_file commits, or all other commits
      #
      # Returns an array of shas
      def git_filter_shas(stack, extra_cmd, old_rev, new_rev, path=nil, filter_files=[], including=false)
        path ||= git_checkout_path(checkout_root, stack)
        including_shas = []
        excluding_shas = []
        cmd = "cd #{path} && git log --no-merges --name-only --pretty=format:%H #{old_rev}..#{new_rev}"
        cmd = build_git_cmd(cmd, extra_cmd)
        committers = run_cmd(cmd)[:stdout]
        committers.split(/\n\n/).each { |commit|
          lines = commit.split(/\n/)
          commit_sha = lines.shift
          has_filter_file = false
          filter_files.each { |filter_file|
            if !has_filter_file && lines.include?(filter_file)
              has_filter_file = true
            end
          }
          if has_filter_file
            including_shas.push(commit_sha)
            #add to the exclude shas list as well if there are more than one file
            excluding_shas.push(commit_sha) unless lines.length == 1
          else
            excluding_shas.push(commit_sha)
          end
        }
        if including
          return including_shas
        else
          return excluding_shas
        end
      end

      # Public: Handles get and store of the head rev from a local
      # file cache.  Call this instead of get_git_head_rev.
      #
      # Paramaters:
      #   stack  - name of the stack for the repo
      #   branch - name of the branch to test
      #
      # Returns the rev as a string
      def git_head_rev(stack, branch="master")
        filename = "#{@@rev_head_cache}_#{stack}"
        head_rev = get_from_cache(filename, @@rev_head_cache_ttl)

        unless head_rev
          head_rev = get_git_head_rev(stack, branch)
          File.open(filename, 'w') {|f| f.write(head_rev) }
        end

        return head_rev
      end

      # Public: get the short sha of the remote HEAD rev of a stack repo.
      # Beware that a true git short rev can also be longer than git_sha_length chars and
      # this way of retrieving it is no guarantee to get a unique short rev.
      # But the alternative is cloning the repo and do a git rev-parse --short
      #
      # Parameters:
      #   stack  - name of the stack for the repo
      #   branch - name of the branch to test (default: master)
      #
      # Returns the rev as a string
      def get_git_head_rev(stack, branch='master', protocol='git')
        cmd = %x{git ls-remote -h #{git_url(stack, protocol)} #{branch} | cut -c1-#{Deployinator.git_sha_length}}.chomp
      end

      # Public: helper method which wraps git clone
      #
      # Examples:
      #  git_clone('web', 'git@github.com:web.git)
      #
      # stack         - the stack to clone
      # repo_url      - the remote url of the repo to clone
      # extra_cmd     - command to prepend before the actual command
      # checkout_root - base directory to clone into
      # branch        - Git branch to checkout. Defaults to 'master'.
      #
      # Returns nothing
      def git_clone(stack, repo_url, extra_cmd="", checkout_root=checkout_root, branch='master')
        path =  git_checkout_path(checkout_root, stack)
        cmd = "git clone #{repo_url} -b #{branch} #{path}"
        cmd = build_git_cmd(cmd, extra_cmd)
        run_cmd cmd
      end

      # Public: helper method to build github urls
      #
      # Example:
      #  git_url('web', 'git', false)
      #
      # stack        - the stack whose github url we want
      # protocol     - 'https', 'http' or 'git'
      # read_write   - if true then we give back a git url we can push to
      #
      # Returns string
      def git_url(stack, protocol="git", read_write=false)
        stack = stack.intern
        repo = git_info_for_stack[stack][:repository]
        github_host = which_github_host(stack)
        repo += ".git" if protocol != "git"
        if (read_write)
          return "git@#{github_host}:#{git_info_for_stack[stack][:user]}/#{repo}"
        else
          return "#{protocol}://#{github_host}/#{git_info_for_stack[stack][:user]}/#{repo}"
        end
      end

      # Public: helper method to determine which github hostname to use
      #
      # Example:
      #  which_github_host('statsd')
      #
      # stack - the stack for the github host we are looking for
      #
      # Returns string
      def which_github_host(stack)
        github_host = git_info_for_stack[stack][:host] rescue nil
        github_host || Deployinator.github_host
      end

      def which_github_host_http_proto(stack)
        github_host_http_proto = git_info_for_stack[stack][:github_host_http_proto] rescue nil
        github_host_http_proto || Deployinator.git_info[:github_host_http_proto] || 'https'
      end

      def git_info
        Deployinator.git_info || {}
      end

      def git_info_for_stack
        Deployinator.git_info_for_stack || {}
      end

      # Public: determines whether a given filesystem path is a git repo
      #
      # path      - the path to the directory to test
      # extra_cmd - optional extra_cmd to prepend to the testing command
      #             (default: "")
      #
      # Examples
      #     is_git_repo('/home/dev/repo')
      #     is_git_repo('/home/dev/repo', 'ssh dev@deployhost')
      #
      # Returns :true if it is a git repo,
      #         :false if the path exists but is not a git repo,
      #         :missing if the path doesn't exist
      def is_git_repo(path, extra_cmd="")
        cmd = "#{extra_cmd} test"
        is_dir  = system("#{cmd} -d #{path}")
        is_file = system("#{cmd} -f #{path}")
        is_git  = system("#{cmd} -d #{path}/.git")

        # check possibilities
        if is_dir
          return :true if is_git
          return :false
        elsif is_file
          return :false
        else
          return :missing
        end
      end

      # Public: determine whether we want to use the github diff based on the
      # existence of the stack key in the github info dict
      #
      # Returns true for existing keys and false otherwise
      def use_github_diff
        git_info_for_stack.has_key? @stack.to_sym
      end

      def github_list_committers(github_commits_param)
        commits = {}
        unless github_commits_param.nil?
          github_commits_param.each do |c|
            name = c["commit"]["committer"]["name"]
            sha  = c["sha"]
            message = c["commit"]["message"]
            commits[sha] = { :name => name, :message => message}
          end
        end
        return commits
      end

      # Public: list the files that changes between 2 revs
      #
      # Parameters:
      #   rev1: string of the older rev
      #   rev2: string of the newer rev
      #   ssh_cmd: string ssh cmd to get to a host where you've got this repo checked out
      #   extra: string any extra cmds like cd that you need to do on the remote host to get to your checkout
      #   quiet: boolean - if true we make no additional output and just return the files
      #
      # Returns:
      #   Array of files names changed between these revs
      def git_show_changed_files(rev1, rev2, ssh_cmd, extra=nil, quiet=false)
        cmd = %Q{git log --name-only --pretty=oneline --full-index #{rev1}..#{rev2} | grep -vE '^[0-9a-f]{40} ' | sort | uniq}
        extra = "#{extra} &&" unless extra.nil?
        if quiet
          list_of_touched_files = %x{#{ssh_cmd} "#{extra} #{cmd}"}
        else
          list_of_touched_files = run_cmd(%Q{#{ssh_cmd} "#{extra} #{cmd}"})[:stdout]
        end
        return list_of_touched_files.split("\n")
      end

      def git_tag_remote_head(stack, tag, message, update=false, branch=nil)
        stack = stack.intern
        branch = branch || git_info_for_stack[stack][:branch]
        repo = "#{git_info_for_stack[stack][:user]}/#{git_info_for_stack[stack][:repository]}"

        existing_ref = @@octokit.ref(repo, "tags/#{tag}")[:object][:sha] rescue nil
        return false if existing_ref and ! update

        head_digest = @@octokit.ref(repo,"heads/#{branch}")[:object][:sha]

        new_tag = @@octokit.create_tag(
          repo,
          tag,
          message,
          head_digest,
          'commit',
          'LiteBright Deployment',
          'devops@truecar.com',
          DateTime.now.to_s
        )

        if existing_ref
          new_ref = @@octokit.update_ref(repo, "tags/#{tag}", new_tag[:sha])
        else
          new_ref = @@octokit.create_ref(repo, "tags/#{tag}", new_tag[:sha])
        end

        return new_ref[:object][:sha]
      end

    end
  end
end
