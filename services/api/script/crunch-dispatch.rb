#!/usr/bin/env ruby

include Process

$warned = {}
$signal = {}
%w{TERM INT}.each do |sig|
  signame = sig
  Signal.trap(sig) do
    $stderr.puts "Received #{signame} signal"
    $signal[:term] = true
  end
end

if ENV["CRUNCH_DISPATCH_LOCKFILE"]
  lockfilename = ENV.delete "CRUNCH_DISPATCH_LOCKFILE"
  lockfile = File.open(lockfilename, File::RDWR|File::CREAT, 0644)
  unless lockfile.flock File::LOCK_EX|File::LOCK_NB
    abort "Lock unavailable on #{lockfilename} - exit"
  end
end

ENV["RAILS_ENV"] = ARGV[0] || ENV["RAILS_ENV"] || "development"

require File.dirname(__FILE__) + '/../config/boot'
require File.dirname(__FILE__) + '/../config/environment'
require 'open3'

class Dispatcher
  include ApplicationHelper

  def sysuser
    return act_as_system_user
  end

  def refresh_todo
    @todo = Job.queue.select do |j| j.repository end
    @todo_pipelines = PipelineInstance.queue
  end

  def sinfo
    @@slurm_version ||= Gem::Version.new(`sinfo --version`.match(/\b[\d\.]+\b/)[0])
    if Gem::Version.new('2.3') <= @@slurm_version
      `sinfo --noheader -o '%n:%t'`.strip
    else
      # Expand rows with hostname ranges (like "foo[1-3,5,9-12]:idle")
      # into multiple rows with one hostname each.
      `sinfo --noheader -o '%N:%t'`.split("\n").collect do |line|
        tokens = line.split ":"
        if (re = tokens[0].match /^(.*?)\[([-,\d]+)\]$/)
          re[2].split(",").collect do |range|
            range = range.split("-").collect(&:to_i)
            (range[0]..range[-1]).collect do |n|
              [re[1] + n.to_s, tokens[1..-1]].join ":"
            end
          end
        else
          tokens.join ":"
        end
      end.flatten.join "\n"
    end
  end

  def update_node_status
    if Server::Application.config.crunch_job_wrapper.to_s.match /^slurm/
      @node_state ||= {}
      node_seen = {}
      begin
        sinfo.split("\n").
          each do |line|
          re = line.match /(\S+?):+(idle|alloc|down)/
          next if !re

          # sinfo tells us about a node N times if it is shared by N partitions
          next if node_seen[re[1]]
          node_seen[re[1]] = true

          # update our database (and cache) when a node's state changes
          if @node_state[re[1]] != re[2]
            @node_state[re[1]] = re[2]
            node = Node.where('hostname=?', re[1]).order(:last_ping_at).last
            if node
              $stderr.puts "dispatch: update #{re[1]} state to #{re[2]}"
              node.info['slurm_state'] = re[2]
              if not node.save
                $stderr.puts "dispatch: failed to update #{node.uuid}: #{node.errors.messages}"
              end
            elsif re[2] != 'down'
              $stderr.puts "dispatch: sinfo reports '#{re[1]}' is not down, but no node has that name"
            end
          end
        end
      rescue => error
        $stderr.puts "dispatch: error updating node status: #{error}"
      end
    end
  end

  def positive_int(raw_value, default=nil)
    value = begin raw_value.to_i rescue 0 end
    if value > 0
      value
    else
      default
    end
  end

  NODE_CONSTRAINT_MAP = {
    # Map Job runtime_constraints keys to the corresponding Node info key.
    'min_ram_mb_per_node' => 'total_ram_mb',
    'min_scratch_mb_per_node' => 'total_scratch_mb',
    'min_cores_per_node' => 'total_cpu_cores',
  }

  def nodes_available_for_job_now(job)
    # Find Nodes that satisfy a Job's runtime constraints (by building
    # a list of Procs and using them to test each Node).  If there
    # enough to run the Job, return an array of their names.
    # Otherwise, return nil.
    need_procs = NODE_CONSTRAINT_MAP.each_pair.map do |job_key, node_key|
      Proc.new do |node|
        positive_int(node.info[node_key], 0) >=
          positive_int(job.runtime_constraints[job_key], 0)
      end
    end
    min_node_count = positive_int(job.runtime_constraints['min_nodes'], 1)
    usable_nodes = []
    Node.find_each do |node|
      good_node = (node.info['slurm_state'] == 'idle')
      need_procs.each { |node_test| good_node &&= node_test.call(node) }
      if good_node
        usable_nodes << node
        if usable_nodes.count >= min_node_count
          return usable_nodes.map { |node| node.hostname }
        end
      end
    end
    nil
  end

  def nodes_available_for_job(job)
    # Check if there are enough idle nodes with the Job's minimum
    # hardware requirements to run it.  If so, return an array of
    # their names.  If not, up to once per hour, signal start_jobs to
    # hold off launching Jobs.  This delay is meant to give the Node
    # Manager an opportunity to make new resources available for new
    # Jobs.
    #
    # The exact timing parameters here might need to be adjusted for
    # the best balance between helping the longest-waiting Jobs run,
    # and making efficient use of immediately available resources.
    # These are all just first efforts until we have more data to work
    # with.
    nodelist = nodes_available_for_job_now(job)
    if nodelist.nil? and not did_recently(:wait_for_available_nodes, 3600)
      $stderr.puts "dispatch: waiting for nodes for #{job.uuid}"
      @node_wait_deadline = Time.now + 5.minutes
    end
    nodelist
  end

  def start_jobs
    @todo.each do |job|
      next if @running[job.uuid]

      cmd_args = nil
      case Server::Application.config.crunch_job_wrapper
      when :none
        if @running.size > 0
            # Don't run more than one at a time.
            return
        end
        cmd_args = []
      when :slurm_immediate
        nodelist = nodes_available_for_job(job)
        if nodelist.nil?
          if Time.now < @node_wait_deadline
            break
          else
            next
          end
        end
        cmd_args = ["salloc",
                    "--chdir=/",
                    "--immediate",
                    "--exclusive",
                    "--no-kill",
                    "--job-name=#{job.uuid}",
                    "--nodelist=#{nodelist.join(',')}"]
      else
        raise "Unknown crunch_job_wrapper: #{Server::Application.config.crunch_job_wrapper}"
      end

      next if !take(job)

      if Server::Application.config.crunch_job_user
        cmd_args.unshift("sudo", "-E", "-u",
                         Server::Application.config.crunch_job_user,
                         "PATH=#{ENV['PATH']}",
                         "PERLLIB=#{ENV['PERLLIB']}",
                         "PYTHONPATH=#{ENV['PYTHONPATH']}",
                         "RUBYLIB=#{ENV['RUBYLIB']}",
                         "GEM_PATH=#{ENV['GEM_PATH']}")
      end

      job_auth = ApiClientAuthorization.
        new(user: User.where('uuid=?', job.modified_by_user_uuid).first,
            api_client_id: 0)
      job_auth.save

      crunch_job_bin = (ENV['CRUNCH_JOB_BIN'] || `which arv-crunch-job`.strip)
      if crunch_job_bin == ''
        raise "No CRUNCH_JOB_BIN env var, and crunch-job not in path."
      end

      require 'shellwords'

      arvados_internal = Rails.configuration.git_internal_dir
      if not File.exists? arvados_internal
        $stderr.puts `mkdir -p #{arvados_internal.shellescape} && cd #{arvados_internal.shellescape} && git init --bare`
      end

      src_repo = File.join(Rails.configuration.git_repositories_dir, job.repository + '.git')
      src_repo = File.join(Rails.configuration.git_repositories_dir, job.repository, '.git') unless File.exists? src_repo

      unless src_repo
        $stderr.puts "dispatch: #{File.join Rails.configuration.git_repositories_dir, job.repository} doesn't exist"
        sleep 1
        untake(job)
        next
      end

      $stderr.puts `cd #{arvados_internal.shellescape} && git fetch-pack --all #{src_repo.shellescape} && git tag #{job.uuid.shellescape} #{job.script_version.shellescape}`

      cmd_args << crunch_job_bin
      cmd_args << '--job-api-token'
      cmd_args << job_auth.api_token
      cmd_args << '--job'
      cmd_args << job.uuid
      cmd_args << '--git-dir'
      cmd_args << arvados_internal

      $stderr.puts "dispatch: #{cmd_args.join ' '}"

      begin
        i, o, e, t = Open3.popen3(*cmd_args)
      rescue
        $stderr.puts "dispatch: popen3: #{$!}"
        sleep 1
        untake(job)
        next
      end

      $stderr.puts "dispatch: job #{job.uuid}"
      start_banner = "dispatch: child #{t.pid} start #{Time.now.ctime.to_s}"
      $stderr.puts start_banner

      @running[job.uuid] = {
        stdin: i,
        stdout: o,
        stderr: e,
        wait_thr: t,
        job: job,
        stderr_buf: '',
        started: false,
        sent_int: 0,
        job_auth: job_auth,
        stderr_buf_to_flush: '',
        stderr_flushed_at: 0,
        bytes_logged: 0,
        events_logged: 0,
        log_truncated: false
      }
      i.close
      update_node_status
    end
  end

  def take(job)
    # no-op -- let crunch-job take care of locking.
    true
  end

  def untake(job)
    # no-op -- let crunch-job take care of locking.
    true
  end

  def read_pipes
    @running.each do |job_uuid, j|
      job = j[:job]

      # Throw away child stdout
      begin
        j[:stdout].read_nonblock(2**20)
      rescue Errno::EAGAIN, EOFError
      end

      # Read whatever is available from child stderr
      stderr_buf = false
      begin
        stderr_buf = j[:stderr].read_nonblock(2**20)
      rescue Errno::EAGAIN, EOFError
      end

      if stderr_buf
        j[:stderr_buf] << stderr_buf
        if j[:stderr_buf].index "\n"
          lines = j[:stderr_buf].lines("\n").to_a
          if j[:stderr_buf][-1] == "\n"
            j[:stderr_buf] = ''
          else
            j[:stderr_buf] = lines.pop
          end
          lines.each do |line|
            $stderr.print "#{job_uuid} ! " unless line.index(job_uuid)
            $stderr.puts line
            pub_msg = "#{Time.now.ctime.to_s} #{line.strip} \n"
            j[:stderr_buf_to_flush] << pub_msg
          end

          if (Rails.configuration.crunch_log_bytes_per_event < j[:stderr_buf_to_flush].size or
              (j[:stderr_flushed_at] + Rails.configuration.crunch_log_seconds_between_events < Time.now.to_i))
            write_log j
          end
        end
      end
    end
  end

  def reap_children
    return if 0 == @running.size
    pid_done = nil
    j_done = nil

    if false
      begin
        pid_done = waitpid(-1, Process::WNOHANG | Process::WUNTRACED)
        if pid_done
          j_done = @running.values.
            select { |j| j[:wait_thr].pid == pid_done }.
            first
        end
      rescue SystemCallError
        # I have @running processes but system reports I have no
        # children. This is likely to happen repeatedly if it happens at
        # all; I will log this no more than once per child process I
        # start.
        if 0 < @running.select { |uuid,j| j[:warned_waitpid_error].nil? }.size
          children = @running.values.collect { |j| j[:wait_thr].pid }.join ' '
          $stderr.puts "dispatch: IPC bug: waitpid() error (#{$!}), but I have children #{children}"
        end
        @running.each do |uuid,j| j[:warned_waitpid_error] = true end
      end
    else
      @running.each do |uuid, j|
        if j[:wait_thr].status == false
          pid_done = j[:wait_thr].pid
          j_done = j
        end
      end
    end

    return if !pid_done

    job_done = j_done[:job]
    $stderr.puts "dispatch: child #{pid_done} exit"
    $stderr.puts "dispatch: job #{job_done.uuid} end"

    # Ensure every last drop of stdout and stderr is consumed
    read_pipes
    write_log j_done # write any remaining logs

    if j_done[:stderr_buf] and j_done[:stderr_buf] != ''
      $stderr.puts j_done[:stderr_buf] + "\n"
    end

    # Wait the thread
    j_done[:wait_thr].value

    jobrecord = Job.find_by_uuid(job_done.uuid)
    if jobrecord.started_at
      # Clean up state fields in case crunch-job exited without
      # putting the job in a suitable "finished" state.
      jobrecord.running = false
      jobrecord.finished_at ||= Time.now
      if jobrecord.success.nil?
        jobrecord.success = false
      end
      jobrecord.save!
    else
      # Don't fail the job if crunch-job didn't even get as far as
      # starting it. If the job failed to run due to an infrastructure
      # issue with crunch-job or slurm, we want the job to stay in the
      # queue.
    end

    # Invalidate the per-job auth token
    j_done[:job_auth].update_attributes expires_at: Time.now

    @running.delete job_done.uuid
  end

  def update_pipelines
    expire_tokens = @pipe_auth_tokens.dup
    @todo_pipelines.each do |p|
      pipe_auth = (@pipe_auth_tokens[p.uuid] ||= ApiClientAuthorization.
                   create(user: User.where('uuid=?', p.modified_by_user_uuid).first,
                          api_client_id: 0))
      puts `export ARVADOS_API_TOKEN=#{pipe_auth.api_token} && arv-run-pipeline-instance --run-here --no-wait --instance #{p.uuid}`
      expire_tokens.delete p.uuid
    end

    expire_tokens.each do |k, v|
      v.update_attributes expires_at: Time.now
      @pipe_auth_tokens.delete k
    end
  end

  def run
    act_as_system_user
    @running ||= {}
    @pipe_auth_tokens ||= { }
    $stderr.puts "dispatch: ready"
    while !$signal[:term] or @running.size > 0
      read_pipes
      if $signal[:term]
        @running.each do |uuid, j|
          if !j[:started] and j[:sent_int] < 2
            begin
              Process.kill 'INT', j[:wait_thr].pid
            rescue Errno::ESRCH
              # No such pid = race condition + desired result is
              # already achieved
            end
            j[:sent_int] += 1
          end
        end
      else
        refresh_todo unless did_recently(:refresh_todo, 1.0)
        update_node_status
        unless @todo.empty? or did_recently(:start_jobs, 1.0) or $signal[:term]
          start_jobs
        end
        unless (@todo_pipelines.empty? and @pipe_auth_tokens.empty?) or did_recently(:update_pipelines, 5.0)
          update_pipelines
        end
      end
      reap_children
      select(@running.values.collect { |j| [j[:stdout], j[:stderr]] }.flatten,
             [], [], 1)
    end
  end

  protected

  def too_many_bytes_logged_for_job(j)
    return (j[:bytes_logged] + j[:stderr_buf_to_flush].size >
            Rails.configuration.crunch_limit_log_event_bytes_per_job)
  end

  def too_many_events_logged_for_job(j)
    return (j[:events_logged] >= Rails.configuration.crunch_limit_log_events_per_job)
  end

  def did_recently(thing, min_interval)
    @did_recently ||= {}
    if !@did_recently[thing] or @did_recently[thing] < Time.now - min_interval
      @did_recently[thing] = Time.now
      false
    else
      true
    end
  end

  # send message to log table. we want these records to be transient
  def write_log running_job
    begin
      if (running_job && running_job[:stderr_buf_to_flush] != '')
        # Truncate logs if they exceed crunch_limit_log_event_bytes_per_job
        # or crunch_limit_log_events_per_job.
        if (too_many_bytes_logged_for_job(running_job))
          return if running_job[:log_truncated]
          running_job[:log_truncated] = true
          running_job[:stderr_buf_to_flush] =
              "Server configured limit reached (crunch_limit_log_event_bytes_per_job: #{Rails.configuration.crunch_limit_log_event_bytes_per_job}). Subsequent logs truncated"
        elsif (too_many_events_logged_for_job(running_job))
          return if running_job[:log_truncated]
          running_job[:log_truncated] = true
          running_job[:stderr_buf_to_flush] =
              "Server configured limit reached (crunch_limit_log_events_per_job: #{Rails.configuration.crunch_limit_log_events_per_job}). Subsequent logs truncated"
        end
        log = Log.new(object_uuid: running_job[:job].uuid,
                      event_type: 'stderr',
                      owner_uuid: running_job[:job].owner_uuid,
                      properties: {"text" => running_job[:stderr_buf_to_flush]})
        log.save!
        running_job[:bytes_logged] += running_job[:stderr_buf_to_flush].size
        running_job[:events_logged] += 1
        running_job[:stderr_buf_to_flush] = ''
        running_job[:stderr_flushed_at] = Time.now.to_i
      end
    rescue
      running_job[:stderr_buf] = "Failed to write logs \n"
      running_job[:stderr_buf_to_flush] = ''
      running_job[:stderr_flushed_at] = Time.now.to_i
    end
  end

end

# This is how crunch-job child procs know where the "refresh" trigger file is
ENV["CRUNCH_REFRESH_TRIGGER"] = Rails.configuration.crunch_refresh_trigger

Dispatcher.new.run
