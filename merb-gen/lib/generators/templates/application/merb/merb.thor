#!/usr/bin/env ruby
require 'rubygems'
require 'thor'
require 'fileutils'
require 'yaml'

# TODO
# - pulling a specific UUID/Tag (gitspec hash) with clone/update
# - a 'deploy' task (in addition to 'redeploy' ?)
# - eventually take a --orm option for the 'merb-stack' type of tasks
# - add merb:gems:refresh to refresh all gems (from specifications)
# - merb:gems:uninstall should remove local bin/ entries

##############################################################################
#
# GemManagement
#
# The following code is also used by Merb core, but we can't rely on it as a
# dependency, since merb.thor should be completely selfcontained (except for
# Thor itself). Therefore, the code below is copied here. Should you work on
# this code, be sure to edit the original code to keep them in sync.
#
##############################################################################

require 'rubygems/dependency_installer'
require 'rubygems/uninstaller'
require 'rubygems/dependency'

module GemManagement
  
  class SourcePathMissing < Exception
  end

  class GemPathMissing < Exception
  end

  # Install a gem - looks remotely and local gem cache;
  # won't process rdoc or ri options.
  def install_gem(gem, options = {})
    from_cache = (options.key?(:cache) && options.delete(:cache))
    if from_cache
      install_gem_from_cache(gem, options)
    else
      version = options.delete(:version)
      Gem.configuration.update_sources = false

      update_source_index(options[:install_dir]) if options[:install_dir]

      installer = Gem::DependencyInstaller.new(options.merge(:user_install => false))
      exception = nil
      begin
        installer.install gem, version
      rescue Gem::InstallError => e
        exception = e
      rescue Gem::GemNotFoundException => e
        if from_cache && gem_file = find_gem_in_cache(gem, version)
          puts "Located #{gem} in gem cache..."
          installer.install gem_file
        else
          exception = e
        end
      rescue => e
        exception = e
      end
      if installer.installed_gems.empty? && exception
        puts "Failed to install gem '#{gem} (#{version})' (#{exception.message})"
      end
      installer.installed_gems.each do |spec|
        puts "Successfully installed #{spec.full_name}"
      end
    end
  end

  # Install a gem - looks in the system's gem cache instead of remotely;
  # won't process rdoc or ri options.
  def install_gem_from_cache(gem, options = {})
    version = options.delete(:version)
    Gem.configuration.update_sources = false
    installer = Gem::DependencyInstaller.new(options.merge(:user_install => false))
    exception = nil
    begin
      if gem_file = find_gem_in_cache(gem, version)
        puts "Located #{gem} in gem cache..."
        installer.install gem_file
      else
        raise Gem::InstallError, "Unknown gem #{gem}"
      end
    rescue Gem::InstallError => e
      exception = e
    end
    if installer.installed_gems.empty? && exception
      puts "Failed to install gem '#{gem}' (#{e.message})"
    end
    installer.installed_gems.each do |spec|
      puts "Successfully installed #{spec.full_name}"
    end
  end

  # Install a gem from source - builds and packages it first then installs.
  def install_gem_from_src(gem_src_dir, options = {})
    raise SourcePathMissing unless File.directory?(gem_src_dir)
    raise GemPathMissing if options[:install_dir] && !File.directory?(options[:install_dir])

    gem_name = File.basename(gem_src_dir)
    gem_pkg_dir = File.expand_path(File.join(gem_src_dir, 'pkg'))

    # We need to use local bin executables if available.
    thor = "#{Gem.ruby} -S #{which('thor')}"
    rake = "#{Gem.ruby} -S #{which('rake')}"

    # Handle pure Thor installation instead of Rake
    if File.exists?(File.join(gem_src_dir, 'Thorfile'))
      # Remove any existing packages.
      FileUtils.rm_rf(gem_pkg_dir) if File.directory?(gem_pkg_dir)
      # Create the package.
      FileUtils.cd(gem_src_dir) { system("#{thor} :package") }
      # Install the package using rubygems.
      if package = Dir[File.join(gem_pkg_dir, "#{gem_name}-*.gem")].last
        FileUtils.cd(File.dirname(package)) do
          install_gem(File.basename(package), options.dup)
          return
        end
      else
        raise Gem::InstallError, "No package found for #{gem_name}"
      end
    # Handle standard installation through Rake
    else
      # Clean and regenerate any subgems for meta gems.
      Dir[File.join(gem_src_dir, '*', 'Rakefile')].each do |rakefile|
        FileUtils.cd(File.dirname(rakefile)) { system("#{rake} clobber_package; #{rake} package") }
      end

      # Handle the main gem install.
      if File.exists?(File.join(gem_src_dir, 'Rakefile'))
        # Remove any existing packages.
        FileUtils.cd(gem_src_dir) { system("#{rake} clobber_package") }
        # Create the main gem pkg dir if it doesn't exist.
        FileUtils.mkdir_p(gem_pkg_dir) unless File.directory?(gem_pkg_dir)
        # Copy any subgems to the main gem pkg dir.
        Dir[File.join(gem_src_dir, '**', 'pkg', '*.gem')].each do |subgem_pkg|
          FileUtils.cp(subgem_pkg, gem_pkg_dir)
        end

        # Finally generate the main package and install it; subgems
        # (dependencies) are local to the main package.
        FileUtils.cd(gem_src_dir) do
          system("#{rake} package")
          FileUtils.cd(gem_pkg_dir) do
            if package = Dir[File.join(gem_pkg_dir, "#{gem_name}-*.gem")].last
              # If the (meta) gem has it's own package, install it.
              install_gem(File.basename(package), options.dup)
            else
              # Otherwise install each package seperately.
              Dir["*.gem"].each { |gem| install_gem(gem, options.dup) }
            end
          end
          return
        end
      end
    end
    raise Gem::InstallError, "No Rakefile found for #{gem_name}"
  end

  # Uninstall a gem.
  def uninstall_gem(gem, options = {})
    if options[:version] && !options[:version].is_a?(Gem::Requirement)
      options[:version] = Gem::Requirement.new ["= #{options[:version]}"]
    end
    update_source_index(options[:install_dir]) if options[:install_dir]
    Gem::Uninstaller.new(gem, options).uninstall
  end

  # Use the local bin/* executables if available.
  def which(executable)
    if File.executable?(exec = File.join(Dir.pwd, 'bin', executable))
      exec
    else
      executable
    end
  end
  
  # Create a modified executable wrapper in the specified bin directory.
  def ensure_local_bin_for(gem_dir, bin_dir, *gems)
    if bin_dir && File.directory?(bin_dir)
      gems.each do |gem|
        if gemspec_path = Dir[File.join(gem_dir, 'specifications', "#{gem}-*.gemspec")].last
          spec = Gem::Specification.load(gemspec_path)
          spec.executables.each do |exec|
            if File.exists?(executable = File.join(gem_dir, 'bin', exec))
              local_executable = File.join(bin_dir, exec)
              puts "Adding local executable #{local_executable}"
              File.open(local_executable, 'w', 0755) do |f|
                f.write(executable_wrapper(spec, exec))
              end
            end
          end
        end
      end
    end
  end

  def executable_wrapper(spec, bin_file_name)
    <<-TEXT
#!#{Gem.ruby}
#
# This file was generated by Merb's GemManagement.
#
# The application '#{spec.name}' is installed as part of a gem, and
# this file is here to facilitate running it.
#

begin 
  require 'minigems'
rescue LoadError 
  require 'rubygems'
end

if File.directory?(gems_dir = File.join(File.dirname(__FILE__), '..', 'gems'))
  $BUNDLE = true; Gem.clear_paths; Gem.path.unshift(gems_dir)
end

version = "#{Gem::Requirement.default}"

if ARGV.first =~ /^_(.*)_$/ and Gem::Version.correct? $1 then
  version = $1
  ARGV.shift
end

gem '#{spec.name}', version
load '#{bin_file_name}'
TEXT
  end

  private

  def find_gem_in_cache(gem, version)
    spec = if version
      version = Gem::Requirement.new ["= #{version}"] unless version.is_a?(Gem::Requirement)
      Gem.source_index.find_name(gem, version).first
    else
      Gem.source_index.find_name(gem).sort_by { |g| g.version }.last
    end
    if spec && File.exists?(gem_file = "#{spec.installation_path}/cache/#{spec.full_name}.gem")
      gem_file
    end
  end

  def update_source_index(dir)
    Gem.source_index.load_gems_in(File.join(dir, 'specifications'))
  end
  
end

##############################################################################

module MerbThorHelper

  private

  # The current working directory, or Merb app root (--merb-root option).
  def working_dir
    @_working_dir ||= File.expand_path(options['merb-root'] || Dir.pwd)
  end

  # We should have a ./src dir for local and system-wide management.
  def source_dir
    @_source_dir  ||= File.join(working_dir, 'src')
    create_if_missing(@_source_dir)
    @_source_dir
  end

  # If a local ./gems dir is found, it means we are in a Merb app.
  def application?
    gem_dir
  end

  # If a local ./gems dir is found, return it.
  def gem_dir
    if File.directory?(dir = File.join(working_dir, 'gems'))
      dir
    end
  end

  # If we're in a Merb app, we can have a ./bin directory;
  # create it if it's not there.
  def bin_dir
    @_bin_dir ||= begin
      if gem_dir
        dir = File.join(working_dir, 'bin')
        create_if_missing(dir)
        dir
      end
    end
  end
  
  def config_dir
    @_config_dir ||= File.join(working_dir, 'config')
  end
  
  def config_file
    @_config_file ||= File.join(config_dir, 'dependencies.yml')
  end
  
  # Find the latest merb-core and gather its dependencies.
  # We check for 0.9.8 as a minimum release version.
  def core_dependencies
    @_core_dependencies ||= begin
      if gem_dir
        Gem.clear_paths; Gem.path.unshift(gem_dir)
      end
      deps = []
      merb_core = Gem::Dependency.new('merb-core', '>= 0.9.8')
      if gemspec = Gem.source_index.search(merb_core).last
        deps << Gem::Dependency.new('merb-core', gemspec.version)
        deps += gemspec.dependencies
      end
      Gem.clear_paths
      deps
    end
  end
  
  # Find local gems and return matched version numbers.
  def find_dependency_versions(dependency)
    versions = []
    specs = Dir[File.join(gem_dir, 'specifications', "#{dependency.name}-*.gemspec")]
    unless specs.empty?
      specs.inject(versions) do |versions, gemspec_path|
        versions << gemspec_path[/-([\d\.]+)\.gemspec$/, 1]
      end
    end
    versions.sort.reverse
  end
  
  # Helper to create dir unless it exists.
  def create_if_missing(path)
    FileUtils.mkdir(path) unless File.exists?(path)
  end
  
  def ensure_local_bin_for(*gems)
    Merb.ensure_local_bin_for(gem_dir, bin_dir, *gems)
  end
  
  def ensure_local_bin_for_core_components
    ensure_local_bin_for('merb-core', 'rake', 'rspec', 'thor', 'merb-gen')
  end
  
end

##############################################################################

class Merb < Thor
  
  extend GemManagement
  
  # Default Git repositories
  def self.default_repos
    @_default_repos ||= { 
      'merb-core'     => "git://github.com/wycats/merb-core.git",
      'merb-more'     => "git://github.com/wycats/merb-more.git",
      'merb-plugins'  => "git://github.com/wycats/merb-plugins.git",
      'extlib'        => "git://github.com/sam/extlib.git",
      'dm-core'       => "git://github.com/sam/dm-core.git",
      'dm-more'       => "git://github.com/sam/dm-more.git",
      'thor'          => "git://github.com/wycats/thor.git" 
    }
  end

  # Git repository sources - pass source_config option to load a yaml 
  # configuration file - defaults to ./config/git-sources.yml and
  # ~/.merb/git-sources.yml - which need to create yourself if desired. 
  #
  # Example of contents:
  #
  # merb-core: git://github.com/myfork/merb-core.git
  # merb-more: git://github.com/myfork/merb-more.git
  def self.repos(source_config = nil)
    source_config ||= begin
      local_config = File.join(Dir.pwd, 'config', 'git-sources.yml')
      user_config  = File.join(ENV["HOME"] || ENV["APPDATA"], '.merb', 'git-sources.yml')
      File.exists?(local_config) ? local_config : user_config
    end
    if source_config && File.exists?(source_config)
      default_repos.merge(YAML.load(File.read(source_config)))
    else
      default_repos
    end
  end
  
  class Dependencies < Thor

    include MerbThorHelper
    
    # List all dependencies by extracting them from the actual application; 
    # will differentiate between locally available gems and system gems. 
    # Local gems will be shown with the installed gem version numbers.
    
    desc 'list', 'List all application dependencies'
    method_options "--merb-root" => :optional,
                   "--local"     => :boolean,
                   "--system"    => :boolean
    def list
      partitioned = { :local => [], :system => [] }
      (core_dependencies + extract_dependencies).each do |dependency|
        if gem_dir && !(versions = find_dependency_versions(dependency)).empty?
          partitioned[:local]  << "#{dependency} [#{versions.join(', ')}]"
        else
          partitioned[:system] << "#{dependency}"
        end
      end
      none = options[:system].nil? && options[:local].nil?
      if (options[:system] || none) && !partitioned[:system].empty?
        puts "System dependencies:"
        partitioned[:system].each { |str| puts "- #{str}" }
      end
      if (options[:local] || none) && !partitioned[:local].empty?
        puts "Local dependencies:"
        partitioned[:local].each  { |str| puts "- #{str}" }
      end
    end
    
    # Install the gems listed in dependencies.yml from RubyForge (stable).
    # Will also install local bin wrappers for known components.
    
    desc 'install', 'Install the gems listed in ./config/dependencies.yml'
    method_options "--merb-root" => :optional,
                   "--cache"     => :boolean,
                   "--binaries"  => :boolean
    def install
      if File.exists?(config_file)
        dependencies = parse_dependencies_yaml(File.read(config_file))
        gems = Gems.new
        gems.options = options
        dependencies.each do |dependency|
          gems.install(dependency.name, dependency.version_requirements.to_s)
        end
        # if options[:binaries] is set this is already taken care of - skip it
        ensure_local_bin_for_core_components unless options[:binaries]
      else
        puts "No configuration file found at #{config_file}"
        puts "Please run merb:dependencies:configure first."
      end
    end
    
    # Retrieve all application dependencies and store them in a local
    # configuration file at ./config/dependencies.yml
    # 
    # The format of this YAML file is as follows:
    # - merb_helpers (>= 0, runtime)
    # - merb-slices (> 0.9.4, runtime)
    
    desc 'configure', 'Retrieve and store dependencies in ./config/dependencies.yml'
    method_options "--merb-root" => :optional,
                   "--force"     => :boolean
    def configure
      entries = (core_dependencies + extract_dependencies).map { |d| d.to_s }
      FileUtils.mkdir_p(config_dir) unless File.directory?(config_dir)
      config = YAML.dump(entries)
      puts "#{config}\n"
      if File.exists?(config_file) && !options[:force]
        puts "File already exists! Use --force to overwrite."
      else
        File.open(config_file, 'w') { |f| f.write config }
        puts "Written #{config_file}:"
      end
    rescue  
      puts "Failed to write to #{config_file}"  
    end
    
    protected
        
    # Extract the runtime dependencies by starting the application in runner mode.
    def extract_dependencies
      FileUtils.cd(working_dir) do
        cmd = ["require 'yaml';"]
        cmd << "dependencies = Merb::BootLoader::Dependencies.dependencies"
        cmd << "entries = dependencies.map { |d| d.to_s }"
        cmd << "puts YAML.dump(entries)"
        output = `merb -r "#{cmd.join("\n")}"`
        if index = (lines = output.split(/\n/)).index('--- ')
          yaml = lines.slice(index, lines.length - 1).join("\n")
          return parse_dependencies_yaml(yaml)
        end
      end
      return []
    end
    
    # Parse the basic YAML config data, and process Gem::Dependency output.
    # Formatting example: merb_helpers (>= 0.9.8, runtime)
    def parse_dependencies_yaml(yaml)
      dependencies = []
      entries = YAML.load(yaml) rescue []
      entries.each do |entry|
        if matches = entry.match(/^(\S+) \(([^,]+)?, ([^\)]+)\)/)
          name, version_req, type = matches.captures
          dependencies << Gem::Dependency.new(name, version_req, type.to_sym)
        else
          puts "Invalid entry: #{entry}"
        end
      end
      dependencies
    end
    
  end  

  # Install a Merb stack from stable RubyForge gems. Optionally install a
  # suitable Rack adapter/server when setting --adapter to one of the
  # following: mongrel, emongrel, thin or ebb.

  desc 'stable', 'Install extlib, merb-core and merb-more from rubygems'
  method_options "--merb-root" => :optional,
                 "--adapter"   => :optional
  def stable
    adapters = %w[mongrel emongrel thin ebb]
    stable = Stable.new
    stable.options = options
    if stable.core && stable.more
      puts "Installed extlib, merb-core and merb-more"
      if options[:adapter] && adapters.include?(options[:adapter]) &&
        stable.refresh_from_gems(options[:adapter])
        puts "Installed #{options[:adapter]}"
      elsif options[:adapter]
        puts "Please specify one of the following adapters: #{adapters.join(' ')}"
      end
    end
  end

  class Stable < Thor

    # The Stable tasks deal with known -stable- gems; available
    # as shortcuts to Merb and DataMapper gems.
    #
    # These are pulled from rubyforge and installed into into the
    # desired gems dir (either system-wide or into the application's
    # gems directory).

    include MerbThorHelper

    # Gets latest gem versions from RubyForge and installs them.
    #
    # Examples:
    #
    # thor merb:edge:core
    # thor merb:edge:core --merb-root ./path/to/your/app
    # thor merb:edge:core --sources ./path/to/sources.yml

    desc 'core', 'Install extlib and merb-core from rubygems'
    method_options "--merb-root" => :optional
    def core
      refresh_from_gems 'extlib', 'merb-core'
      ensure_local_bin_for('merb-core', 'rake', 'rspec', 'thor')
    end

    desc 'more', 'Install merb-more from rubygems'
    method_options "--merb-root" => :optional
    def more
      refresh_from_gems 'merb-more'
      ensure_local_bin_for('merb-gen')
    end

    desc 'plugins', 'Install merb-plugins from rubygems'
    method_options "--merb-root" => :optional
    def plugins
      refresh_from_gems 'merb-plugins'
    end

    desc 'dm_core', 'Install dm-core from rubygems'
    method_options "--merb-root" => :optional
    def dm_core
      refresh_from_gems 'extlib', 'dm-core'
    end

    desc 'dm_more', 'Install dm-more from rubygems'
    method_options "--merb-root" => :optional
    def dm_more
      refresh_from_gems 'extlib', 'dm-core', 'dm-more'
    end

    # Pull from RubyForge and install.
    def refresh_from_gems(*components)
      gems = Gems.new
      gems.options = options
      components.all? { |name| gems.install(name) }
    end

  end

  # Retrieve latest Merb versions from git and optionally install them.
  #
  # Note: the --sources option takes a path to a YAML file
  # with a regular Hash mapping gem names to git urls.
  #
  # Examples:
  #
  # thor merb:edge
  # thor merb:edge --install
  # thor merb:edge --merb-root ./path/to/your/app
  # thor merb:edge --sources ./path/to/sources.yml

  desc 'edge', 'Install extlib, merb-core and merb-more from git HEAD'
  method_options "--merb-root" => :optional,
                 "--sources"   => :optional,
                 "--install"   => :boolean
  def edge
    edge = Edge.new
    edge.options = options
    edge.core
    edge.more
    edge.custom
  end

  class Edge < Thor

    # The Edge tasks deal with known gems from the bleeding edge; available
    # as shortcuts to Merb and DataMapper gems.
    #
    # These are pulled from git and optionally installed into into the
    # desired gems dir (either system-wide or into the application's
    # gems directory).

    include MerbThorHelper

    # Gets latest gem versions from git - optionally installs them.
    #
    # Note: the --sources option takes a path to a YAML file
    # with a regular Hash mapping gem names to git urls,
    # allowing pulling forks of the official repositories.
    #
    # Examples:
    #
    # thor merb:edge:core
    # thor merb:edge:core --install
    # thor merb:edge:core --merb-root ./path/to/your/app
    # thor merb:edge:core --sources ./path/to/sources.yml

    desc 'core', 'Update extlib and merb-core from git HEAD'
    method_options "--merb-root" => :optional,
                   "--sources"   => :optional,
                   "--install"   => :boolean
    def core
      refresh_from_source 'thor', 'extlib', 'merb-core'
      ensure_local_bin_for('merb-core', 'rake', 'rspec', 'thor')
    end

    desc 'more', 'Update merb-more from git HEAD'
    method_options "--merb-root" => :optional,
                   "--sources"   => :optional,
                   "--install"   => :boolean
    def more
      refresh_from_source 'merb-more'
      ensure_local_bin_for('merb-gen')
    end

    desc 'plugins', 'Update merb-plugins from git HEAD'
    method_options "--merb-root" => :optional,
                   "--sources"   => :optional,
                   "--install"   => :boolean
    def plugins
      refresh_from_source 'merb-plugins'
    end

    desc 'dm_core', 'Update dm-core from git HEAD'
    method_options "--merb-root" => :optional,
                   "--sources"   => :optional,
                   "--install"   => :boolean
    def dm_core
      refresh_from_source 'extlib', 'dm-core'
    end

    desc 'dm_more', 'Update dm-more from git HEAD'
    method_options "--merb-root" => :optional,
                   "--sources"   => :optional,
                   "--install"   => :boolean
    def dm_more
      refresh_from_source 'extlib', 'dm-core', 'dm-more'
    end

    desc 'custom', 'Update all the custom repos from git HEAD'
    method_options "--merb-root" => :optional,
                   "--sources"   => :optional,
                   "--install"   => :boolean
    def custom
      custom_repos = Merb.repos.keys - Merb.default_repos.keys
      refresh_from_source *custom_repos
    end

    private

    # Pull from git and optionally install the resulting gems.
    def refresh_from_source(*components)
      source = Source.new
      source.options = options
      components.each do |name|
        source.clone(name)
        source.install(name) if options[:install]
      end
    end

  end

  class Source < Thor

    # The Source tasks deal with gem source packages - mainly from github.
    # Any directory inside ./src is regarded as a gem that can be packaged
    # and installed from there into the desired gems dir (either system-wide
    # or into the application's gems directory).

    include MerbThorHelper

    # Install a particular gem from source.
    #
    # If a local ./gems dir is found, or --merb-root is given
    # the gems will be installed locally into that directory.
    #
    # Note that this task doesn't retrieve any (new) source from git;
    # To update and install you'd execute the following two tasks:
    #
    # thor merb:source:update merb-core
    # thor merb:source:install merb-core
    #
    # Alternatively, look at merb:edge and merb:edge:* with --install.
    #
    # Examples:
    #
    # thor merb:source:install merb-core
    # thor merb:source:install merb-more
    # thor merb:source:install merb-more/merb-slices
    # thor merb:source:install merb-plugins/merb_helpers
    # thor merb:source:install merb-core --merb-root ./path/to/your/app

    desc 'install GEM_NAME', 'Install a rubygem from (git) source'
    method_options "--merb-root" => :optional
    def install(name)
      puts "Installing #{name}..."
      gem_src_dir = File.join(source_dir, name)
      opts = {}
      opts[:install_dir] = gem_dir   if gem_dir
      Merb.install_gem_from_src(gem_src_dir, opts)
    rescue Merb::SourcePathMissing
      puts "Missing rubygem source path: #{gem_src_dir}"
    rescue Merb::GemPathMissing
      puts "Missing rubygems path: #{gem_dir}"
    rescue => e
      puts "Failed to install #{name} (#{e.message})"
    end

    # Clone a git repository into ./src. The repository can be
    # a direct git url or a known -named- repository.
    #
    # Examples:
    #
    # thor merb:source:clone dm-core
    # thor merb:source:clone dm-core --sources ./path/to/sources.yml
    # thor merb:source:clone git://github.com/sam/dm-core.git

    desc 'clone REPOSITORY', 'Clone a git repository into ./src'
    method_options "--sources" => :optional
    def clone(repository)
      if repository =~ /^git:\/\//
        repository_url = repository
      elsif url = Merb.repos(options[:sources])[repository]
        repository_url = url
      end

      if repository_url
        repository_name = repository_url[/([\w+|-]+)\.git/u, 1]
        fork_name = repository_url[/.com\/+?(.+)\/.+\.git/u, 1]
        local_repo_path =  "#{source_dir}/#{repository_name}"

        if File.directory?(local_repo_path)
          puts "\n#{repository_name} repository exists, updating or branching instead of cloning..."
          FileUtils.cd(local_repo_path) do

            # to avoid conflicts we need to set a remote branch for non official repos
            existing_repos  = `git remote -v`.split("\n").map{|branch| branch.split(/\s+/)}
            origin_repo_url = existing_repos.detect{ |r| r.first == "origin" }.last

            # pull from the original repository - no branching needed
            if repository_url == origin_repo_url
              puts "Pulling from #{repository_url}"
              system %{
                git fetch
                git checkout master
                git rebase origin/master
              }
            # update and switch to a branch for a particular github fork
            elsif existing_repos.map{ |r| r.last }.include?(repository_url)
              puts "Switching to remote branch: #{fork_name}"
              `git checkout -b #{fork_name} #{fork_name}/master`
              `git rebase #{fork_name}/master`
            # create a new remote branch for a particular github fork
            else
              puts "Add a new remote branch: #{fork_name}"
              `git remote add -f #{fork_name} #{repository_url}`
              `git checkout -b#{fork_name} #{fork_name}/master`
            end
          end
        else
          FileUtils.cd(source_dir) do
            puts "\nCloning #{repository_name} repository from #{repository_url}..."
            system("git clone --depth 1 #{repository_url} ")
          end
        end
      else
        puts "No valid repository url given"
      end
    end

    # Update a specific gem source directory from git. See #clone.

    desc 'update REPOSITORY', 'Update a git repository in ./src'
    alias :update :clone

    # Update all gem sources from git - based on the current branch.
    # Optionally install the gems when --install is specified.
    
    desc 'refresh', 'Pull fresh copies of all source gems'
    method_options "--install" => :boolean
    def refresh
      repos = Dir["#{source_dir}/*"]
      repos.each do |repo|
        next unless File.directory?(repo) && File.exists?(File.join(repo, '.git'))
        FileUtils.cd(repo) do
          gem_name = File.basename(repo)
          puts "Refreshing #{gem_name}"
          system %{git fetch}
          branch = `git branch --no-color 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/(\1) /'`[/\* (.+)/, 1]
          system %{git rebase #{branch}}
          install(gem_name) if options[:install]
        end
      end
    end

  end

  class Gems < Thor

    # The Gems tasks deal directly with rubygems, either through remotely
    # available sources (rubyforge for example) or by searching the
    # system-wide gem cache for matching gems. The gems are installed from
    # there into the desired gems dir (either system-wide or into the
    # application's gems directory).

    include MerbThorHelper

    # Install a gem and its dependencies.
    #
    # If a local ./gems dir is found, or --merb-root is given
    # the gems will be installed locally into that directory.
    #
    # The option --cache will look in the system's gem cache
    # for the latest version and install it in the apps' gems.
    # This is particularly handy for gems that aren't available
    # through rubyforge.org - like in-house merb slices etc.
    #
    # Examples:
    #
    # thor merb:gems:install merb-core
    # thor merb:gems:install merb-core --cache
    # thor merb:gems:install merb-core --version 0.9.7
    # thor merb:gems:install merb-core --merb-root ./path/to/your/app

    desc 'install GEM_NAME', 'Install a gem from rubygems'
    method_options "--version"   => :optional,
                   "--merb-root" => :optional,
                   "--cache"     => :boolean,
                   "--binaries"  => :boolean
    def install(name, version = nil)
      puts "Installing #{name}..."
      opts = {}
      opts[:version] = version || options[:version]
      opts[:cache] = options[:cache] if gem_dir
      opts[:install_dir] = gem_dir   if gem_dir
      Merb.install_gem(name, opts)
      ensure_local_bin_for(name) if options[:binaries]
    rescue => e
      puts "Failed to install #{name} (#{e.message})"
    end

    # Update a gem and its dependencies.
    #
    # If a local ./gems dir is found, or --merb-root is given
    # the gems will be installed locally into that directory.
    #
    # The option --cache will look in the system's gem cache
    # for the latest version and install it in the apps' gems.
    # This is particularly handy for gems that aren't available
    # through rubyforge.org - like in-house merb slices etc.
    #
    # Examples:
    #
    # thor merb:gems:update merb-core
    # thor merb:gems:update merb-core --cache
    # thor merb:gems:update merb-core --merb-root ./path/to/your/app

    desc 'update GEM_NAME', 'Update a gem from rubygems'
    method_options "--merb-root" => :optional,
                   "--cache"     => :boolean,
                   "--binaries"  => :boolean
    def update(name)
      puts "Updating #{name}..."
      opts = {}
      if gem_dir
        if gemspec_path = Dir[File.join(gem_dir, 'specifications', "#{name}-*.gemspec")].last
          gemspec = Gem::Specification.load(gemspec_path)
          opts[:version] = Gem::Requirement.new [">#{gemspec.version}"]
        end
        opts[:install_dir] = gem_dir
        opts[:cache] = options[:cache]
      end
      Merb.install_gem(name, opts)
      ensure_local_bin_for(name) if options[:binaries]
    rescue => e
      puts "Failed to update #{name} (#{e.message})"
    end

    # Uninstall a gem - ignores dependencies.
    #
    # If a local ./gems dir is found, or --merb-root is given
    # the gems will be uninstalled locally from that directory.
    #
    # The --all option indicates that all versions of the gem should be
    # uninstalled. If --version isn't set, and multiple versions are
    # available, you will be prompted to pick one - or all.
    #
    # Examples:
    #
    # thor merb:gems:uninstall merb-core
    # thor merb:gems:uninstall merb-core --all
    # thor merb:gems:uninstall merb-core --version 0.9.7
    # thor merb:gems:uninstall merb-core --merb-root ./path/to/your/app

    desc 'uninstall GEM_NAME', 'Uninstall a gem'
    method_options "--version"   => :optional,
                   "--merb-root" => :optional,
                   "--all" => :boolean
    def uninstall(name, version = nil)
      puts "Uninstalling #{name}..."
      opts = {}
      opts[:ignore] = true
      opts[:all] = options[:all]
      opts[:executables] = true
      opts[:version] = version || options[:version]
      opts[:install_dir] = gem_dir if gem_dir
      Merb.uninstall_gem(name, opts.merge(options))
    rescue => e
      puts "Failed to uninstall #{name} (#{e.message})"
    end

    # Completely remove a gem and all its versions - ignores dependencies.
    #
    # If a local ./gems dir is found, or --merb-root is given
    # the gems will be uninstalled locally from that directory.
    #
    # Examples:
    #
    # thor merb:gems:wipe merb-core
    # thor merb:gems:wipe merb-core --merb-root ./path/to/your/app

    desc 'wipe GEM_NAME', 'Remove a gem completely'
    method_options "--merb-root" => :optional
    def wipe(name)
      puts "Wiping #{name}..."
      opts = {}
      opts[:ignore] = true
      opts[:all] = true
      opts[:executables] = true
      opts[:install_dir] = gem_dir if gem_dir
      Merb.uninstall_gem(name, opts)
    rescue => e
      puts "Failed to wipe #{name} (#{e.message})"
    end
    
    # Refresh all local gems by uninstalling them and subsequently reinstall
    # the latest versions from stable sources.
    #
    # A local ./gems dir is required, or --merb-root is given
    # the gems will be uninstalled locally from that directory.
    #
    # Examples:
    #
    # thor merb:gems:refresh
    # thor merb:gems:refresh --merb-root ./path/to/your/app
    
    desc 'refresh', 'Refresh all local gems by installing only the most recent versions'
    method_options "--merb-root" => :optional,
                   "--cache"     => :boolean,
                   "--binaries"  => :boolean
    def refresh
      if gem_dir
        gem_names = []
        local_gemspecs.each do |spec|
          gem_names << spec.name unless gem_names.include?(spec.name)
          uninstall(spec.name, spec.version)
        end
        gem_names.each { |name| install(name) }
        # if options[:binaries] is set this is already taken care of - skip it
        ensure_local_bin_for_core_components unless options[:binaries]
      else
        puts "The refresh task only works with local gems"
      end      
    end
    
    # This task should be executed as part of a deployment setup, where
    # the deployment system runs this after the app has been installed.
    # Usually triggered by Capistrano, God...
    #
    # It will regenerate gems from the bundled gems cache for any gem
    # that has C extensions - which need to be recompiled for the target
    # deployment platform.

    desc 'redeploy', 'Recreate any binary gems on the target deployment platform'
    def redeploy
      require 'tempfile' # for
      if gem_dir && File.directory?(cache_dir = File.join(gem_dir, 'cache'))
        local_gemspecs.each do |gemspec|
          unless gemspec.extensions.empty?
            if File.exists?(gem_file = File.join(cache_dir, "#{gemspec.full_name}.gem"))
              gem_file_copy = File.join(Dir::tmpdir, File.basename(gem_file))
              # Copy the gem to a temporary file, because otherwise RubyGems/FileUtils
              # will complain about copying identical files (same source/destination).
              FileUtils.cp(gem_file, gem_file_copy)
              Merb.install_gem(gem_file_copy, :install_dir => gem_dir)
              File.delete(gem_file_copy)
            end
          end
        end
        # Regenerate local bin wrappers with the proper Ruby shebang for
        # the target platform - we're using Gem.ruby not 'env ruby';
        # be sure to execute thor with the right Ruby binary:
        # /path/to/exotic/ruby -S thor merb:gems:redeploy
        ensure_local_bin_for_core_components
      else
        puts "No application local gems directory found"
      end
    end
    
    protected
    
    def local_gemspecs(directory = gem_dir)
      if File.directory?(specs_dir = File.join(directory, 'specifications'))
        Dir[File.join(specs_dir, '*.gemspec')].map do |gemspec_path|
          gemspec = Gem::Specification.load(gemspec_path)
          gemspec.loaded_from = gemspec_path
          gemspec
        end
      else
        []
      end
    end

  end

  class Tasks < Thor

    include MerbThorHelper

    # Install Thor, Rake and RSpec into the local gems dir, by copying it from
    # the system-wide rubygems cache - which is OK since we needed it to run
    # this task already.
    #
    # After this we don't need the system-wide rubygems anymore, as all required
    # executables are available in the local ./bin directory.
    #
    # RSpec is needed here because source installs might fail when running
    # rake tasks where spec/rake/spectask has been required.

    desc 'setup', 'Install Thor, Rake and RSpec in the local gems dir'
    method_options "--merb-root" => :optional
    def setup
      if $0 =~ /^(\.\/)?bin\/thor$/
        puts "You cannot run the setup from #{$0} - try #{File.basename($0)} merb:tasks:setup instead"
        return
      end
      create_if_missing(File.join(working_dir, 'gems'))
      Merb.install_gem('thor',  :cache => true, :install_dir => gem_dir)
      Merb.install_gem('rake',  :cache => true, :install_dir => gem_dir)
      Merb.install_gem('rspec', :cache => true, :install_dir => gem_dir)
      ensure_local_bin_for('thor', 'rake', 'rspec')
    end

    # Get the latest merb.thor and install it into the working dir.

    desc 'update', 'Fetch the latest merb.thor and install it locally'
    def update
      require 'open-uri'
      url = 'http://merbivore.com/merb.thor'
      remote_file = open(url)
      File.open(File.join(working_dir, 'merb.thor'), 'w') do |f|
        f.write(remote_file.read)
      end
      puts "Installed the latest merb.thor"
    rescue OpenURI::HTTPError
      puts "Error opening #{url}"
    rescue => e
      puts "An error occurred (#{e.message})"
    end

  end

end