# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# The pure rules: naming, records, resolution, status.
class TestJobsDeclaration < Minitest::Test
  J = Asgard::Jobs

  def test_job_name_table
    assert_nil J.job_name(nil, task: :build)
    assert_nil J.job_name(false, task: :build)
    assert_equal :'servers-1', J.job_name(true, task: :servers, sequence: 1)
    assert_equal :api,  J.job_name(:api, task: :servers)
    assert_equal :api,  J.job_name(" api ", task: nil), "a String is stripped and symbolized, and needs no task"
    assert_equal :web_2, J.job_name("web_2", task: :servers)
  end

  def test_job_name_rejects_what_the_requirements_rule_out
    error = assert_raises(ArgumentError) { J.job_name(true, task: nil, sequence: 1) }
    assert_match(/must be called from a task body/, error.message)
    ["api-1", "my api", "", :'x.y'].each do |bad|
      error = assert_raises(ArgumentError) { J.job_name(bad, task: :t) }
      assert_match(/not a job name/, error.message)
    end
    error = assert_raises(ArgumentError) { J.job_name(42, task: :t) }
    assert_match(/must be true, a Symbol or a String/, error.message)
  end

  # J6: a task named ready? or deploy! still gives a listable job name.
  def test_regression_j6_sequenced_names_are_file_safe
    assert_equal :'ready-q-1', J.job_name(true, task: :ready?, sequence: 1)
    assert_equal :'deploy-b-2', J.job_name(true, task: :deploy!, sequence: 2)
    assert_match Asgard::Jobs::State::RECORD, "#{J.job_name(true, task: :ready?, sequence: 1)}.json"
  end

  # B6: foo? and foo_ both became foo_-1, so one task's start found the
  # other's job "already running". Every task name gets its own job name.
  def test_regression_b6_sequenced_names_never_collide
    assert_equal :'foo_-1',          J.job_name(true, task: :foo_, sequence: 1)
    assert_equal :'set-e-1',         J.job_name(true, task: :set=, sequence: 1)
    assert_equal :'a--b-1',          J.job_name(true, task: :'a-b', sequence: 1)
    assert_equal :'pi-u0003c0-1',    J.job_name(true, task: :piπ, sequence: 1)
    tasks = %i[foo foo? foo! foo_ foo= foo_q foo-q foo-q-1 foo- foo-- foo-u0003c0 fooπ foo_b]
    names = tasks.flat_map { |task| [1, 2].map { |n| J.job_name(true, task:, sequence: n) } }
    assert_equal names.size, names.uniq.size, names.tally.select { |_, count| count > 1 }.inspect
    names.each { |name| assert_match Asgard::Jobs::State::RECORD, "#{name}.json" }
  end

  def valid_record = { name: "api", task: "t", pid: 4242, pgid: 4242, script: "/s/api.sh", started: "2026-10-24T10:00:00+00:00" }

  # B1: a readable record that is not a job's (a hand edit, another tool)
  # is skipped instead of crashing every listing.
  def test_regression_b1_valid_record_requires_what_a_job_needs
    assert J.valid_record?(valid_record)
    [nil, [1], "x", { name: "bad", pid: 1 }].each { |bad| refute J.valid_record?(bad), bad.inspect }
    { name: [nil, "", 7], pid: [nil, 0, 1, -4, "4242", 4242.0], pgid: [nil, 1, "4242"],
      script: [nil, "", 3], started: [nil, "", "yesterday", 5] }.each do |key, values|
      values.each { |value| refute J.valid_record?(valid_record.merge(key => value)), "#{key}: #{value.inspect}" }
    end
  end

  def test_summary_is_the_first_non_blank_line
    assert_equal "mkdocs serve", J.summary("\n\n  mkdocs serve  \n  --strict\n")
    assert_equal "", J.summary("  \n")
  end

  def test_record_shape
    record = J.record(name: :api, task: :servers, pid: 7, pgid: 7, cwd: "/p", script: "/s/api.sh", log: "/s/api.log",
                      command: "rails s", started: "2026-10-24T10:00:00+00:00")
    assert_equal %i[name task pid pgid started cwd script log command], record.keys
    assert_equal "api",     record[:name]
    assert_equal "servers", record[:task]
  end

  def test_closure_walks_every_stage_without_repeating
    deps = { servers: [[:db], %i[api web]], api: [[:db]], web: [[:assets]] }
    assert_equal %i[servers db api web assets], J.closure(:servers, deps)
    assert_equal %i[db], J.closure("db", deps)
    assert_equal %i[nothing], J.closure(:nothing, {})
  end

  def test_resolve_prefers_job_names_then_tasks_then_the_closure
    records = [{ name: "servers-1", task: "servers" }, { name: "api", task: "api" }, { name: "db-1", task: "db" }]
    found, unknown = J.resolve(%w[api], records)
    assert_equal [records[1]], found
    assert_empty unknown
    found, = J.resolve(%w[db], records)
    assert_equal [records[2]], found, "a task name finds the jobs it started"
    closure = ->(task) { task == "servers" ? %i[servers api db] : [task.to_sym] }
    found, unknown = J.resolve(%w[servers nope], records, closure:)
    assert_equal records, found
    assert_equal %w[nope], unknown
    found, = J.resolve(%w[servers servers-1], records, closure:)
    assert_equal records, found, "the same record is never listed twice"
  end

  def test_status_and_its_description
    assert_equal :running,     J.status(exit_code: nil, verified: true)
    assert_equal :gone,        J.status(exit_code: nil, verified: false)
    assert_equal [:exited, 3], J.status(exit_code: 3, verified: false)
    assert_equal "running",         J.describe_status(:running)
    assert_equal "gone",            J.describe_status(:gone)
    assert_equal "exited 3 (2.5s)", J.describe_status([:exited, 3], seconds: 2.5)
    assert_equal "exited 0",        J.describe_status([:exited, 0])
  end

  # B2: a job whose script exited while processes it started remain in
  # its group says so.
  def test_regression_b2_status_shows_processes_left
    assert_equal [:exited, 0, :processes_left], J.status(exit_code: 0, verified: false, leftovers: true)
    assert_equal [:exited, 0], J.status(exit_code: 0, verified: false, leftovers: false)
    assert_equal "exited 0 (1.0s, processes left)", J.describe_status([:exited, 0, :processes_left], seconds: 1.0)
    assert_equal "exited 0 (processes left)",       J.describe_status([:exited, 0, :processes_left])
  end
end

# Shared scaffolding for the tests that start real processes: HOME and
# XDG_STATE_HOME under a temp dir, a temp project with a .loki, and every
# job's process group killed afterwards.
module JobsSandbox
  def setup
    @saved   = ENV.to_h.slice("HOME", "XDG_STATE_HOME", "PYTHONUNBUFFERED")
    @cwd     = Dir.pwd
    @tmp     = File.realpath(Dir.mktmpdir)
    @project = File.join(@tmp, "proj")
    FileUtils.mkdir_p(@project)
    File.write(File.join(@project, ".loki"), "")
    ENV["HOME"] = @tmp
    ENV["XDG_STATE_HOME"] = File.join(@tmp, "state")
    ENV.delete("PYTHONUNBUFFERED")
    @slug = Asgard::Schedule.project_slug(@project)
    Dir.chdir(@project)
  end

  def teardown
    Dir.chdir(@cwd)
    kill_jobs
    @saved.each { |key, value| ENV[key] = value }
    ENV.delete("PYTHONUNBUFFERED") unless @saved.key?("PYTHONUNBUFFERED")
    Asgard::Shell.reset_shells!
    FileUtils.rm_rf(@tmp)
  end

  # Only a job that still verifies as ours is signalled, and only through
  # Stopper.signal_group, which refuses anything that is not a group id
  # above 1. Fixture records carry pgid 1, and kill(2) reads -1 as every
  # process the user owns: a bare Process.kill here once killed every
  # program on the machine.
  def kill_jobs
    Dir.glob(File.join(@tmp, "state", "asgard", "jobs", "*", "*.json")).each do |file|
      record = Asgard::StateDir.read_json(file)
      next unless Asgard::Jobs::State.active?(record)

      Asgard::Jobs::Stopper.signal_group("KILL", record[:pgid])
    rescue Errno::EPERM, ArgumentError
      nil
    end
  end

  def state = @state ||= Asgard::Jobs::State.new(project: @slug, root: @project)

  # The pid of a child that has already been reaped: a real pid above 1
  # that no process of ours holds, for fixture records that must not be
  # running. Fixtures pair it with a script path no command line carries.
  def dead_pid
    pid = Process.spawn("true")
    Process.wait(pid)
    pid
  end

  # A record that passes Jobs.valid_record? but whose job is not running.
  def fixture(name, target = state, **fields)
    pid = dead_pid
    { name:, task: "t", pid:, pgid: pid, started: Time.now.iso8601, script: File.join(target.dir, "#{name}.sh"),
      command: "c" }.merge(fields)
  end

  def run_for(script, shell = :bash) = Asgard::Shell::Run.new(name: shell, shell: Asgard::Shell.shell_for(shell), script: script.strip)

  def wait_until(seconds = 10, message = "condition not met")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert yield, "#{message} within #{seconds}s"
  end

  def wait_for_status(name)
    wait_until(10, "no status for #{name}") { state.exit_code(name) }
    state.exit_code(name)
  end

  # Until the job's process group holds a process running +word+: the
  # trampoline has exec'd the job's shell and that shell its command. A
  # TERM sent earlier can land between the trampoline's fork and its
  # exec, where the inherited trap swallows it and the job lives on.
  def wait_for_job_command(record, word = "sleep")
    wait_until(10, "#{record[:name]} never started #{word}") do
      `pgrep -g #{record[:pgid]}`.split.map(&:to_i).any? { |pid| Asgard::Pid.command_line(pid).to_s.include?(word) }
    end
  end
end

class TestJobsState < Minitest::Test
  include JobsSandbox

  def test_paths_live_under_the_jobs_state_home
    dir = File.join(@tmp, "state", "asgard", "jobs", @slug)
    assert_equal dir, state.dir
    assert_equal File.join(dir, "api.json"),   state.record_path("api")
    assert_equal File.join(dir, "api.sh"),     state.script_path("api", ".sh")
    assert_equal File.join(dir, "api.log"),    state.log_path("api")
    assert_equal File.join(dir, "api.status"), state.status_path("api")
    assert_equal File.join(@tmp, "state", "asgard", "jobs"), Asgard::Jobs::State.base_dir
  end

  def test_prepare_records_the_root_and_all_finds_it
    assert_equal [], state.records, "no directory yet is no records"
    state.prepare
    assert_equal [[@slug, @project]], Asgard::Jobs::State.all
  end

  def test_records_round_trip_in_start_order_and_skip_tempfiles
    state.prepare
    b = fixture("b", started: "2026-10-24T10:00:02+00:00")
    state.write_record(b)
    state.write_record(fixture("a", started: "2026-10-24T10:00:01+00:00"))
    File.write(File.join(state.dir, ".asgard-tmp-1.json"), "{")
    assert_equal(%w[a b], state.records.map { |record| record[:name] })
    assert_equal b[:pid], state.read_record("b")[:pid]
    assert_nil state.read_record("c")
  end

  # B1: readable JSON that is not a job record never reaches a listing,
  # and the files are named so `list` can say what it skipped.
  def test_regression_b1_records_skip_what_is_not_a_job_record
    state.prepare
    state.write_record(fixture("good"))
    { "bad" => '{"name":"bad","pid":1}', "list" => "[1]", "broken" => "{",
      "nostart" => '{"name":"nostart","pid":42,"pgid":42,"script":"/s"}' }.each { |name, json| File.write(state.record_path(name), json) }
    assert_equal(%w[good], state.records.map { |record| record[:name] })
    assert_nil state.read_record("bad")
    assert_equal %w[bad broken list nostart], state.invalid_records.map { |path| File.basename(path, ".json") }.sort
    assert_empty Asgard::Jobs::State.new(project: "none", root: "/none").invalid_records
  end

  # B1: an empty script matched every command line, so any live pid,
  # pid 1 included, counted as a running job.
  def test_regression_b1_an_empty_script_never_verifies
    child = Process.spawn("/bin/sleep", "30")
    wait_until { Asgard::Pid.command_line(child).to_s.include?("sleep") }
    record = fixture("api", pid: child, pgid: child)
    assert state.verified?(record.merge(script: Asgard::Pid.command_line(child))), "the scaffolding is a running job"
    refute state.verified?(record.merge(script: "")), "an empty script is no job"
    refute Asgard::Pid.matches?(child, "", self_ok: false), "an empty word matches nothing"
  ensure
    Process.kill("TERM", child)
    Process.wait(child)
  end

  # B3: clean removes a job under its start lock and checks again once
  # it holds it, so a start that raced it keeps its fresh record.
  def test_regression_b3_forget_waits_for_the_lock_and_rechecks
    state.prepare
    state.write_record(fixture("api"))
    held   = Queue.new
    holder = Thread.new do
      state.with_lock("api") do
        held << true
        sleep 0.4
      end
    end
    held.pop
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert state.forget_unless_active("api"), "a stale job is forgotten"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.3, "only once the lock is free"
    holder.join
    assert_nil state.read_record("api")
    refute state.forget_unless_active("api"), "nothing left to forget"
    Asgard::Jobs::Launcher.start(run_for("sleep 30"), name: :api, task: :t, state:, silent: true)
    refute state.forget_unless_active("api"), "a running job is kept"
    assert state.read_record("api")
  end

  # B4: a job KILLed as a group leaves no status behind, so stop writes
  # 137 itself; a status already written is never replaced.
  def test_regression_b4_record_kill_writes_137_once
    state.prepare
    record = fixture("api")
    Asgard::Jobs::State.record_kill(record)
    assert_equal 137, state.exit_code("api")
    File.write(state.status_path("api"), "0\n")
    Asgard::Jobs::State.record_kill(record)
    assert_equal 0, state.exit_code("api")
    Asgard::Jobs::State.record_kill({ name: "api", pid: 42, pgid: 42 })
    assert_equal 0, state.exit_code("api"), "a record that is not a job's writes nothing"
  end

  # B2: what remains in a job's group once its trampoline exited. Pure,
  # with ps stood in for by a callable.
  def test_regression_b2_leftovers_needs_a_safe_group_and_an_old_enough_member
    exited  = Time.now - 60
    member  = ->(started) { ->(_pgid) { [Asgard::Pid::Member.new(pid: 9, started:, command: "sleep 31")] } }
    record  = { name: "api", pid: 4242, pgid: 4242, script: "/s/api.sh" }
    leftovers = ->(rec = record, ps:, at: exited) { Asgard::Jobs::State.leftovers?(rec, exited_at: at, ps:) }
    assert leftovers.call(ps: member.call(exited - 5)), "a member from before the script exited"
    assert leftovers.call(ps: member.call(exited + 0.5)), "within ps's one-second resolution"
    refute leftovers.call(ps: member.call(exited + 30)), "a member younger than that may be a reused group id"
    refute leftovers.call(ps: ->(_) { [] }), "an empty group"
    refute leftovers.call(ps: member.call(exited - 5), at: nil), "no status: the trampoline still runs or never wrote"
    [nil, 0, 1, -4, "4242", Process.getpgrp].each do |pgid|
      refute leftovers.call(record.merge(pgid:), ps: ->(_) { raise "ps asked about #{pgid.inspect}" }), pgid.inspect
    end
  end

  def test_regression_b2_parse_group_reads_pid_age_and_command
    out = "  501   501     01:02 /bin/sh -c x\n  510   777  1-00:00:03 sleep 31\n  " \
          "511   777        05 bash /s/api.sh\n 7770  7770 00:01 other\n"
    now = Time.at(1_000_000)
    members = Asgard::Pid.parse_group(out, 777, now:)
    assert_equal [510, 511], members.map(&:pid)
    assert_equal ["sleep 31", "bash /s/api.sh"], members.map(&:command)
    assert_equal [now - 86_403, now - 5], members.map(&:started)
    assert_equal([5, 62, 3_723, 86_403], %w[05 01:02 01:02:03 1-00:00:03].map { |etime| Asgard::Pid.elapsed_seconds(etime) })
  end

  def test_exit_code_and_remove
    state.prepare
    name = "api"
    state.write_record({ name:, task: "t", pid: 1, started: "2026-10-24T10:00:01+00:00" })
    File.write(state.script_path(name, ".sh"), "x")
    File.write(state.log_path(name), "some output")
    assert_nil state.exit_code(name)
    assert_nil state.exit_time(name)
    File.write(state.status_path(name), "3\n")
    assert_equal 3, state.exit_code(name)
    assert_in_delta Time.now, state.exit_time(name), 5
    state.remove(name)
    assert_equal ["api.log"], Dir.children(state.dir) - ["root"]
    assert_equal "", File.read(state.log_path(name)), "the log stays, emptied"
    state.remove(name, keep_log: false)
    assert_equal [], Dir.children(state.dir) - ["root"]
    state.remove("never_started")
  end

  def test_verified_needs_the_script_path_in_the_command_line
    state.prepare
    script = state.script_path("api", ".sh")
    # Two commands, as in the trampoline, so sh keeps its argv instead of
    # exec'ing sleep away; the script path rides along as $0. Its own
    # group, as a job's is: TERM to sh alone would orphan the sleep, which
    # then holds the test runner's output pipe open for thirty seconds.
    child  = Process.spawn("/bin/sh", "-c", "sleep 30; :", script, pgroup: true)
    other  = Process.spawn("/bin/sleep", "30")
    wait_until { state.verified?(fixture("api", pid: child, pgid: child, script:)) }
    refute state.verified?(fixture("api", pid: other, pgid: other, script:)), "a live process without the script is not ours"
    ended = child
    child = nil
    end_spawned_group(ended)
    refute state.verified?(fixture("api", pid: ended, pgid: ended, script:))
  ensure
    end_spawned_group(child) if child
    Process.kill("TERM", other)
    Process.wait(other)
  end

  # Ends the group +leader+ leads: a pid this test just spawned with
  # pgroup: true, so the group holds only its own processes. Anything but
  # an Integer above 1 that is not our own group is refused, not signalled.
  def end_spawned_group(leader)
    unless leader.is_a?(Integer) && leader > 1 && leader != Process.getpgrp
      raise ArgumentError, "not a group this test spawned: #{leader.inspect}"
    end

    Process.kill("TERM", -leader)
    Process.wait(leader)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end

# B8: a ps that rejects the flags jobs rely on (BusyBox's) must fail
# loudly, not make every job look gone. A real stand-in executable plays
# BusyBox ps.
class TestJobsPs < Minitest::Test
  Pid = Asgard::Pid

  def with_fake_ps(body)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ps")
      File.write(path, "#!/bin/sh\n#{body}\n")
      File.chmod(0o755, path)
      yield path
    end
  end

  def test_regression_b8_the_systems_ps_is_usable
    assert_nil Pid.ps_problem(ps: Pid::PS)
    Pid.require_ps!
  end

  def test_regression_b8_a_ps_that_rejects_our_flags_is_a_clear_error
    with_fake_ps("echo \"ps: invalid option -- 'w'\" >&2; echo 'BusyBox v1.36.1 multi-call binary.' >&2; exit 1") do |ps|
      assert_match(/invalid option -- 'w'/, Pid.ps_problem(ps:))
      error = assert_raises(Pid::Unusable) { Pid.require_ps!(ps:) }
      assert_kind_of Asgard::Error, error
      assert_match(/#{Regexp.escape(ps)} cannot list processes: ps: invalid option -- 'w'/, error.message)
      assert_match(/procps/, error.message)
    end
    with_fake_ps("exit 0") { |ps| assert_match(/printed nothing/, Pid.ps_problem(ps:)) }
    assert_match(/No such file/, Pid.ps_problem(ps: "/no/such/ps"))
  end
end

class TestJobsLauncher < Minitest::Test
  include JobsSandbox

  Launcher = Asgard::Jobs::Launcher

  def test_argv_environment_and_spawn_options_are_pure
    argv = Launcher.argv(%w[bash /s/api.sh])
    assert_equal "/bin/sh", argv.first
    assert_equal %w[asgard-job bash /s/api.sh], argv.last(3)
    assert_includes argv[2], 'trap ":" TERM INT HUP;'
    assert_includes argv[2], '"$@"; echo $? > "$ASGARD_JOB_STATUS"'
    env = Launcher.environment(:api, "/s/api.status", {})
    assert_equal({ "ASGARD_JOB" => "api", "ASGARD_JOB_STATUS" => "/s/api.status", "PYTHONUNBUFFERED" => "1" }, env)
    assert_equal %w[ASGARD_JOB ASGARD_JOB_STATUS], Launcher.environment(:api, "/s", { "PYTHONUNBUFFERED" => "0" }).keys
    assert_equal({ in: File::NULL, %i[out err] => ["/s/api.log", "a"], close_others: true }, Launcher.spawn_options("/s/api.log"))
  end

  def start(script, name: :api, task: :servers, shell: :bash, silent: true, out: StringIO.new)
    Launcher.start(run_for(script, shell), name:, task:, state:, silent:, out:)
  end

  def test_start_runs_the_job_in_its_own_session_with_output_in_the_log
    out = StringIO.new
    job = start("echo hello; sleep 30", silent: false, out:)
    assert_equal :api, job.name
    assert_equal :servers, job.task
    assert_equal "started api (pid #{job.pid}), log: #{job.log}\n", out.string
    assert_equal job.pid, Process.getpgid(job.pid), "the job leads its process group"
    assert_equal job.pid, Process.getsid(job.pid),  "and its session"
    record = state.read_record("api")
    assert_equal({ name: "api", task: "servers", pid: job.pid, pgid: job.pid, cwd: @project, command: "echo hello; sleep 30" },
                 record.slice(:name, :task, :pid, :pgid, :cwd, :command))
    assert_equal state.script_path("api", ".sh"), record[:script]
    assert_equal "echo hello; sleep 30\n", File.read(record[:script])
    assert_in_delta Time.now, Time.iso8601(record[:started]), 5
    wait_until { File.read(job.log).include?("hello") }
    assert state.verified?(record)
    assert_equal :running, Asgard::Jobs.status(exit_code: state.exit_code("api"), verified: true)
    Asgard::Jobs::Stopper.signal_group("TERM", job.pid)
    assert_equal 143, wait_for_status("api"), "the trap lets the trampoline record a signal exit"
    wait_until { !state.verified?(record) }
  end

  def test_an_exit_code_is_recorded_and_the_environment_reaches_the_job
    job = start("echo job=$ASGARD_JOB py=$PYTHONUNBUFFERED; exit 3")
    assert_equal 3, wait_for_status("api")
    wait_until { File.read(job.log).include?("job=api py=1") }
    assert_equal [:exited, 3], Asgard::Jobs.status(exit_code: state.exit_code("api"), verified: state.verified?(state.read_record("api")))
  end

  def test_start_twice_returns_the_running_job_and_starts_nothing
    first = start("sleep 30")
    out   = StringIO.new
    again = start("sleep 30", out:)
    assert_equal first.pid, again.pid
    assert_equal first, again
    assert_match(/\Aapi already running \(pid #{first.pid}, started by servers\), log: #{Regexp.escape(first.log)}\n\z/, out.string)
  end

  def test_a_new_start_of_an_ended_job_replaces_its_record_and_truncates_the_log
    first = start("echo one; exit 1")
    assert_equal 1, wait_for_status("api")
    wait_until { File.read(first.log).include?("one") }
    second = start("echo two; sleep 30")
    refute_equal first.pid, second.pid
    assert_nil state.exit_code("api"), "the old status is gone"
    wait_until { File.read(second.log).include?("two") }
    refute_includes File.read(second.log), "one"
  end

  # J2: two starts of one name at the same moment must leave one job,
  # never two with the second record hiding the first.
  def test_regression_j2_concurrent_starts_of_one_name_start_one_job
    jobs = Array.new(2) { Thread.new { start("sleep 30", out: StringIO.new) } }.map(&:value)
    assert_equal 1, jobs.map(&:pid).uniq.size, "pids: #{jobs.map(&:pid).inspect}"
    assert_equal jobs.first.pid, state.read_record("api")[:pid]
  ensure
    Array(jobs).map(&:pid).uniq.each { |pid| Asgard::Jobs::Stopper.signal_group("KILL", pid) }
  end

  def test_the_job_is_shell_independent
    jobs = { ruby: "$stdout.sync = true; puts 'from ruby'" }
    jobs[:python3] = 'print("from python")' if Asgard::Schedule.which("python3", ENV.fetch("PATH", nil))
    jobs[:zsh]     = "echo from zsh" if Asgard::Schedule.which("zsh", ENV.fetch("PATH", nil))
    jobs.each do |shell, script|
      job = start(script, name: shell, shell:)
      assert_equal 0, wait_for_status(shell), "#{shell} should run to completion"
      wait_until { File.read(job.log).include?("from ") }
      ext = shell == :zsh ? ".sh" : Asgard::Shell.shell_for(shell)[:ext]
      assert_equal state.script_path(shell, ext), state.read_record(shell.to_s)[:script], "#{shell}: an unregistered zsh still gets .sh"
    end
  end

  def test_exec_in_the_script_keeps_the_trampoline_verifiable
    job = start("exec sleep 30")
    wait_until { Asgard::Pid.command_line(job.pid) }
    assert state.verified?(state.read_record("api"))
    refute_includes Asgard::Pid.command_line(job.pid), "sleep", "the recorded pid is the trampoline, not the exec'd command"
  end

  # The pid launch returns must already run the trampoline: a check made
  # between the child's fork and its exec sees the parent's command line,
  # so an immediate second start would not recognise the job as running.
  def test_regression_launch_returns_only_after_the_exec
    pids = Array.new(30) do |i|
      Launcher.launch({}, Launcher.argv(%w[sleep 30]), Launcher.spawn_options(File.join(@tmp, "l#{i}.log")))
    end
    lines = pids.map { |pid| Asgard::Pid.command_line(pid).to_s }
    assert lines.all? { |line| line.include?("asgard-job") }, "not yet exec'd: #{lines.reject { |l| l.include?('asgard-job') }.first}"
  ensure
    pids&.each { |pid| Asgard::Jobs::Stopper.signal_group("KILL", pid) }
  end

  # J6: remove takes exactly one job's files, whatever the name holds.
  def test_regression_j6_remove_touches_only_that_jobs_files
    state.prepare
    %w[a.json ab.json a.log].each { |file| File.write(File.join(state.dir, file), "{}") }
    state.remove("a", keep_log: false)
    assert_equal ["ab.json"], Dir.children(state.dir).grep_v(/\A(?:root|\..*)\z/)
  end

  # J7: an exec that fails in the job's child says why and exits 127,
  # instead of a Ruby backtrace from inside the fork.
  def test_regression_j7_a_failed_exec_reports_and_exits_127
    missing = File.join(@tmp, "no", "such", "dir", "x.log")
    _, err = capture_subprocess_io do
      Launcher.launch({}, Launcher.argv(%w[sleep 30]), Launcher.spawn_options(missing))
      sleep 0.5
    end
    assert_match(/asgard: could not start job/, err)
    refute_match(/from .*launcher\.rb/, err)
  end

  def test_regression_j7_the_job_gets_no_stray_descriptors
    assert_equal true, Launcher.spawn_options("/x.log")[:close_others]
  end

  # J10: a job whose trampoline alone was killed still runs; it is still
  # verified, still stopped, and never cleaned away.
  def test_regression_j10_a_job_without_its_trampoline_is_still_the_job
    job    = start("sleep 30")
    record = state.read_record("api")
    wait_for_job_command(record)
    Process.kill("KILL", job.pid) # the trampoline only: a pid we started, never a group
    wait_until(5, "trampoline gone") { Asgard::Pid.command_line(job.pid).nil? }
    assert Asgard::Jobs::State.verified?(record), "its shell still runs the script in the job's group"
    out = StringIO.new
    assert_equal :stopped, Asgard::Jobs::Stopper.new(out:).stop(record)
    wait_until(5, "group gone") { !Asgard::Jobs::State.verified?(record) }
  end

  def test_a_missing_shell_exits_127_before_anything_is_started
    _, err = capture_io { assert_raises(SystemExit) { start("echo x", shell: :no_such_shell_xyz) }.tap { |e| assert_equal 127, e.status } }
    assert_match(/shell :no_such_shell_xyz not found/, err)
    assert_nil state.read_record("api")
  end
end

# The `background:` keyword, end to end from a task body.
class TestJobsBackgroundKeyword < Minitest::Test
  include JobsSandbox

  def setup
    super
    jobs = @jobs = {}
    @klass = Class.new(Asgard::Base) do
      desc "db", "db"
      define_method(:db) { jobs[:db] = sh("sleep 30", background: true, silent: true) }

      depends_on :db
      desc "servers", "servers"
      define_method(:servers) do
        jobs[:one]   = sh("sleep 30", background: true, silent: true)
        jobs[:named] = shebang(:bash, "sleep 30", background: :api, silent: true)
        jobs[:two]   = sh("sleep 30", background: "two_ ", silent: true)
        jobs[:three] = sh("sleep 30", background: true, silent: true)
      end

      desc "bad", "bad"
      define_method(:bad) { sh("sleep 30", background: "no good") }

      desc "fg", "fg"
      define_method(:fg) { jobs[:fg] = sh("true", silent: true) }
    end
  end

  def test_sequence_numbers_belong_to_the_calling_task_and_named_jobs_take_none
    capture_io { @klass.new([], {}, {}).invoke(:servers) }
    assert_equal :'db-1',      @jobs[:db].name, "a dependency names its jobs after itself"
    assert_equal :'servers-1', @jobs[:one].name
    assert_equal :api,         @jobs[:named].name
    assert_equal :two_,        @jobs[:two].name
    assert_equal :'servers-2', @jobs[:three].name, "named jobs do not consume a sequence number"
    assert_equal %w[api db-1 servers-1 servers-2 two_], state.records.map { |record| record[:name] }.sort
    assert_equal "servers", state.read_record("api")[:task]
    assert_equal true, @jobs[:fg].nil?
  end

  def test_foreground_is_unchanged_and_a_bad_name_raises_before_the_echo
    out, = capture_io { @klass.new([], {}, {}).invoke(:fg) }
    assert_equal "", out
    assert_equal true, @jobs[:fg]
    out, = capture_io { assert_raises(ArgumentError) { @klass.new([], {}, {}).invoke(:bad) } }
    assert_equal "", out, "nothing is echoed for a call that cannot start"
    assert_empty state.records
  end

  def test_the_echo_and_the_started_line
    klass = Class.new(Asgard::Base) do
      desc "serve", "serve"
      def serve = sh "sleep 30", background: true
    end
    out, = capture_io { klass.new([], {}, {}).invoke(:serve) }
    pid = state.read_record("serve-1")[:pid]
    assert_equal "sleep 30\nstarted serve-1 (pid #{pid}), log: #{state.log_path('serve-1')}\n", out
    @klass._reset_ran!
    klass._reset_ran!
    out, = capture_io { klass.new([], {}, {}).invoke(:serve) }
    assert_equal "sleep 30\nserve-1 already running (pid #{pid}, started by serve), log: #{state.log_path('serve-1')}\n", out
  end

  def test_background_true_outside_a_task_is_an_error
    error = assert_raises(ArgumentError) { @klass.new([], {}, {}).sh("sleep 30", background: true) }
    assert_match(/must be called from a task body/, error.message)
  end

  def test_csh_scripts_get_their_own_extension
    assert_equal ".csh", Asgard::Shell.entry("csh")[:ext]
    assert_equal ".csh", Asgard::Shell.entry("/bin/tcsh")[:ext]
  end
end

class TestJobsStopper < Minitest::Test
  include JobsSandbox

  Stopper = Asgard::Jobs::Stopper

  RECORD = { name: "api", pid: 42, pgid: 42 }.freeze

  # A fake job alive for +ticks+ liveness checks after each signal it is
  # sent, with every signal and sleep recorded.
  def stopper(term_survives:, kill_survives: 0, timeout: 1)
    @signals = []
    @sleeps  = []
    left     = { nil => term_survives, "TERM" => term_survives, "KILL" => kill_survives }
    current  = nil
    alive    = lambda do |_record|
      next true if left[current].positive? && (left[current] -= 1) >= 0

      left[current].positive?
    end
    signal = lambda { |name, pgid|
      @signals << [name, pgid]
      current = name
    }
    Stopper.new(timeout:, out: @out = StringIO.new, alive:, signal:, sleeper: ->(seconds) { @sleeps << seconds })
  end

  def test_term_ends_the_job_within_the_grace_period
    assert_equal :stopped, stopper(term_survives: 2).stop(RECORD)
    assert_equal [["TERM", 42]], @signals
    assert_equal [0.2, 0.2], @sleeps
    assert_equal "", @out.string
  end

  def test_kill_follows_when_the_grace_period_runs_out
    stop = stopper(term_survives: 100, kill_survives: 1)
    assert_equal :killed, stop.stop_and_report(RECORD)
    assert_equal [["TERM", 42], ["KILL", 42]], @signals
    assert_equal 6, @sleeps.size, "five polls over a one-second grace period, one after KILL"
    assert_equal "waiting for api (pid 42)\nkilled api (pid 42) after 1s\n", @out.string
  end

  def test_a_job_that_is_not_running_is_reported_as_such
    stop = stopper(term_survives: 0)
    assert_equal :not_running, stop.stop_and_report(RECORD)
    assert_empty @signals
    assert_equal "api is not running\n", @out.string
    assert_equal "stopped api (pid 42)", stop.report_line(:stopped, RECORD)
  end

  # J5: a TERM that lands between the trampoline's fork and its child's
  # exec is swallowed by the inherited trap. A job that ignores the first
  # TERM but obeys the second must stop, not be KILLed.
  def test_regression_j5_term_is_sent_again_during_the_grace_period
    sent  = []
    alive = ->(_record) { sent.count { |name, _| name == "TERM" } < 2 }
    stop  = Stopper.new(timeout: 3, out: StringIO.new, alive:, signal: ->(name, pgid) { sent << [name, pgid] }, sleeper: ->(_) {})
    assert_equal :stopped, stop.stop(RECORD)
    assert_equal [["TERM", 42], ["TERM", 42]], sent
  end

  def test_regression_j5_resend_schedule
    assert_equal([5, 10], (0...12).select { |tick| Stopper.resend_tick?(tick, poll: 0.2) })
  end

  def test_signal_group_refuses_anything_but_a_real_group_id
    [nil, 0, 1, -1, -42, "42", 42.0].each do |bad|
      error = assert_raises(ArgumentError, "pgid #{bad.inspect} must be refused") { Stopper.signal_group("TERM", bad) }
      assert_match(/refusing to signal process group/, error.message)
    end
  end

  def test_signal_group_ignores_a_group_that_is_already_gone
    child = Process.spawn("true", pgroup: true)
    Process.wait(child)
    assert_nil Stopper.signal_group("TERM", child)
  end

  # A group we may not signal (EPERM: its id now belongs to another
  # user's processes) is refused, never a crash. Only the recording
  # stand-in for Process.kill sees a signal here.
  def test_signal_group_refuses_a_group_it_may_not_signal
    eperm = ->(*) { raise Errno::EPERM }
    sent  = []
    kill  = lambda do |signal, target|
      sent << [signal, target]
      raise Errno::EPERM
    end

    assert_equal false, Stopper.signal_group("TERM", 4242, own_pgrp: 99_999, pgid_of: eperm, kill:)
    assert_empty sent

    gone = ->(*) { raise Errno::ESRCH }
    assert_equal false, Stopper.signal_group("TERM", 4242, own_pgrp: 99_999, pgid_of: gone, kill:)
    assert_equal [[0, -4242]], sent

    sent.clear
    assert_equal false, Stopper.signal_group("TERM", 4242, own_pgrp: 99_999, pgid_of: ->(_) { 4242 }, kill:)
    assert_equal [["TERM", -4242]], sent
  end

  # J1: a stale record whose pid is now asgard itself must never verify,
  # or stop would signal asgard's own process group. Only the recording
  # stand-in ever sees the signal; nothing here reaches Process.kill.
  def test_regression_j1_a_record_naming_our_own_pid_is_not_stopped
    sent    = []
    record  = { name: "api", pid: Process.pid, pgid: Process.getpgrp, script: "/no/such/asgard-job-script.sh" }
    stopper = Stopper.new(out: StringIO.new, signal: ->(name, pgid) { sent << [name, pgid] }, sleeper: ->(_) {})
    assert_equal :not_running, stopper.stop(record)
    assert_empty sent, "no signal may be sent to our own group"
  end

  def test_regression_j1_jobs_never_verify_against_our_own_pid
    record = { name: "api", pid: Process.pid, pgid: Process.getpgrp, started: Time.now.iso8601, script: "/no/such/asgard-job-script.sh" }
    refute Asgard::Jobs::State.verified?(record)
  end

  def test_regression_j1_pid_matches_keeps_the_watcher_shortcut_behind_a_keyword
    assert Asgard::Pid.matches?(Process.pid, "absent", command: "other")
    refute Asgard::Pid.matches?(Process.pid, "absent", command: "other", self_ok: false)
    assert Asgard::Pid.matches?(Process.pid, "here", command: "is here", self_ok: false)
  end

  def test_regression_j1_safe_group_refuses_our_group_and_a_group_the_pid_left
    pgid_of = ->(pid) { { 50 => 50, 60 => 61 }.fetch(pid) { raise Errno::ESRCH } }
    assert Stopper.safe_group?(50, pid: 50, own_pgrp: 7, pgid_of:)
    refute Stopper.safe_group?(7, pid: 7, own_pgrp: 7, pgid_of: ->(_) { 7 }), "our own group"
    refute Stopper.safe_group?(60, pid: 60, own_pgrp: 7, pgid_of:), "the pid now leads another group"
    refute Stopper.safe_group?(70, pid: 70, own_pgrp: 7, pgid_of:), "the pid is gone"
    [nil, 0, 1, -5, "50"].each { |bad| refute Stopper.safe_group?(bad, pid: 50, own_pgrp: 7, pgid_of:), bad.inspect }
  end

  # The id is a reaped child's, so even a wrong answer could only reach
  # a group that no longer exists.
  def test_regression_j1_signal_group_refuses_our_own_group
    gone = Process.spawn("true", pgroup: true)
    Process.wait(gone)
    assert_equal false, Stopper.signal_group("TERM", gone, own_pgrp: gone, pgid_of: ->(_) { gone })
  end

  def test_a_real_job_and_its_child_stop_together
    job    = Asgard::Jobs::Launcher.start(run_for("sleep 30"), name: :api, task: :t, state:, silent: true)
    record = state.read_record("api")
    wait_until { Asgard::Pid.command_line(job.pid) }
    sleeper = `pgrep -g #{job.pid}`.split.map(&:to_i) - [job.pid]
    refute_empty sleeper, "the shell and its sleep belong to the job's group"
    out = StringIO.new
    assert_equal :stopped, Stopper.new(out:).stop_and_report(record)
    assert_equal "stopped api (pid #{job.pid})\n", out.string
    refute state.verified?(record)
    wait_until { sleeper.none? { |pid| Asgard::Pid.alive?(pid) } }
    assert_equal 143, wait_for_status("api")
  end

  # B2: a script that backgrounds a process and exits leaves it in the
  # job's group; the listing says so and stop still reaches it.
  def test_regression_b2_processes_left_in_the_group_are_listed_and_stopped
    Asgard::Jobs::Launcher.start(run_for("sleep 31 & sleep 0.3"), name: :api, task: :t, state:, silent: true)
    record = state.read_record("api")
    assert_equal 0, wait_for_status("api")
    left = `pgrep -g #{record[:pgid]}`.split.map(&:to_i)
    assert_equal 1, left.size, "only the backgrounded sleep remains"
    assert_includes Asgard::Pid.command_line(left.first), "sleep 31"
    refute state.verified?(record)
    assert state.active?(record)
    assert_match(/\Aexited 0 \(\d+\.\ds, processes left\)\z/, Asgard::Jobs::Commands.rows(state).first[:state])
    out = StringIO.new
    assert_equal :stopped, Stopper.new(out:).stop_and_report(record)
    assert_equal "stopped api (pid #{record[:pid]})\n", out.string
    wait_until(5, "leftover gone") { !Asgard::Pid.alive?(left.first) }
    refute state.active?(record)
    assert_equal 0, state.exit_code("api"), "the script's own status stands"
  end

  # B4: KILL takes the trampoline down with the group, so the 137 the
  # listing shows is written by stop.
  def test_regression_b4_a_killed_job_shows_exited_137
    Asgard::Jobs::Launcher.start(run_for("trap '' TERM; sleep 30"), name: :api, task: :t, state:, silent: true)
    record = state.read_record("api")
    wait_for_job_command(record)
    assert_equal :killed, Stopper.new(timeout: 0.4, out: StringIO.new).stop(record)
    assert_equal 137, state.exit_code("api")
    assert_match(/\Aexited 137/, Asgard::Jobs::Commands.rows(state).first[:state])
  end
end

# `asgard jobs ...` end to end in a temp project.
class TestJobsCommands < Minitest::Test
  include JobsSandbox

  Commands = Asgard::Jobs::Commands

  def setup
    super
    Tasks.class_eval do
      desc "jobs_test_db", "db"
      def jobs_test_db = sh "sleep 30", background: :jtdb, silent: true

      depends_on :jobs_test_db
      desc "jobs_test_servers", "servers"
      def jobs_test_servers = sh "sleep 30", background: true, silent: true
    end
  end

  def teardown
    super
    %i[jobs_test_db jobs_test_servers].each do |task|
      Tasks.remove_command(task)
      Tasks._deps.delete(task)
      Tasks.send(:remove_method, task) if Tasks.method_defined?(task)
    end
  end

  # Each call stands for a separate `asgard jobs ...` process.
  def jobs(*argv)
    Commands._reset_ran!
    Commands.start(argv)
  end

  def start_servers
    Tasks._reset_ran!
    capture_io { Tasks.start(%w[jobs_test_servers]) }
    state.records.to_h { |record| [record[:name], record] }.each_value { |record| wait_for_job_command(record) }
  end

  def test_asgard_jobs_maps_to_the_subcommand_and_lists_by_default
    Tasks._reset_ran!
    Commands._reset_ran! # an earlier test in this process may already have run `list`
    out, = capture_io { Tasks.start(%w[jobs]) }
    assert_match "No jobs recorded for #{@slug}", out
    assert_match "asgard jobs list --all", out
    out, = capture_io { Commands.start(%w[help]) }
    assert_match " jobs stop", out
    refute_match(/ _jobs /, out)
    assert Asgard.machine_wide?(%w[jobs list])
    refute Asgard.machine_wide?(%w[jobs stop])
  end

  def test_rows_describe_each_record
    state.prepare
    started = Time.new(2026, 10, 24, 9, 30, 0).iso8601
    state.write_record(fixture("gone", started:, command: "sleep 30"))
    done = fixture("done", started:, command: "exit 3")
    state.write_record(done)
    File.write(state.status_path("done"), "3\n")
    rows = Commands.rows(state).to_h { |row| [row[:name], row] }
    assert_equal "gone", rows["gone"][:state]
    assert_match(/\Aexited 3 \(\d+\.\ds\)\z/, rows["done"][:state])
    assert_equal({ task: "t", pid: done[:pid], started: "2026-10-24 09:30:00", command: "exit 3" },
                 rows["done"].slice(:task, :pid, :started, :command))
    assert_equal %w[tail -n +1 -f /l], Commands.tail_argv("/l")
  end

  def test_list_renders_this_project_or_every_project
    records = start_servers
    out, = capture_io { jobs("list") }
    assert_match(/jtdb\s+│\s+jobs_test_db\s+│\s+#{records['jtdb'][:pid]}\s+│\s+running/, out)
    assert_match "jobs_test_servers-1", out
    assert_match "State: #{Asgard::Jobs::State.base_dir}", out
    refute_match "Project:", out
    other = Asgard::Jobs::State.new(project: "other-00000000", root: "/nowhere").prepare
    x = fixture("x", other)
    other.write_record(x)
    out, = capture_io { jobs("list", "--all") }
    assert_match "Project: #{@slug} (#{@project})", out
    assert_match "Project: other-00000000 (/nowhere) [root missing]", out
    assert_match(/x\s+│\s+t\s+│\s+#{x[:pid]}\s+│\s+gone/, out)
    Dir.mktmpdir do |elsewhere|
      Dir.chdir(elsewhere) { out, = capture_io { jobs("list") } }
      assert_match "Project:", out, "with no .loki above, list covers every project"
    end
  end

  def test_stop_by_job_name_task_name_and_closure
    records = start_servers
    out, = capture_io { jobs("stop", "jtdb") }
    assert_equal "stopped jtdb (pid #{records['jtdb'][:pid]})\n", out
    assert_equal 143, wait_for_status("jtdb")
    out, = capture_io { jobs("stop", "jobs_test_servers") }
    assert_equal "stopped jobs_test_servers-1 (pid #{records['jobs_test_servers-1'][:pid]})\njtdb is not running\n", out,
                 "a task name reaches its own jobs and, through depends_on, its dependencies'"
    assert_equal 2, state.records.size, "stop removes nothing"
    out, = capture_io { jobs("stop") }
    assert_equal "jobs_test_servers-1 is not running\njtdb is not running\n", out
  end

  def test_stop_with_nothing_recorded_or_an_unknown_name
    out, = capture_io { jobs("stop") }
    assert_equal "No jobs recorded for #{@slug}.\n", out
    _, err = capture_io { assert_raises(SystemExit) { jobs("stop", "nope") }.tap { |e| assert_equal 1, e.status } }
    assert_equal "jobs: no such job or task: nope\n", err
  end

  # B7: a task that exists but started nothing is not an unknown name.
  def test_regression_b7_stop_names_a_task_with_no_jobs
    out, err = capture_io { jobs("stop", "jobs_test_servers") }
    assert_equal "jobs_test_servers has no running jobs\n", out
    assert_equal "", err
    _, err = capture_io { assert_raises(SystemExit) { jobs("stop", "jobs_test_db", "nope") } }
    assert_equal "jobs: no such job or task: nope\n", err
  end

  # B1: one readable but malformed record crashed list, list --all and
  # stop with a backtrace, and clean kept it forever.
  def test_regression_b1_a_malformed_record_is_skipped_noted_and_cleaned
    state.prepare
    state.write_record(fixture("good"))
    File.write(state.record_path("bad"), '{"name":"bad","pid":1}')
    File.write(state.record_path("list"), "[1]")
    out, err = capture_io { jobs("list") }
    assert_match(/good\s+│/, out)
    refute_match(/bad|list/, out)
    assert_equal "jobs: skipped #{state.record_path('bad')}: not a job record\n" \
                 "jobs: skipped #{state.record_path('list')}: not a job record\n", err
    out, = capture_io { jobs("list", "--all") }
    assert_match(/good\s+│/, out)
    _, err = capture_io { assert_raises(SystemExit) { jobs("stop", "bad") } }
    assert_equal "jobs: no such job or task: bad\n", err
    out, = capture_io { jobs("clean") }
    assert_equal "removed bad (not a job record)\nremoved list (not a job record)\nremoved good\n", out
    assert_equal ["root"], Dir.children(state.dir).grep_v(/\A\./)
  end

  def test_stop_kills_a_job_that_ignores_term_and_exits_nonzero
    Tasks._reset_ran!
    klass = Class.new(Asgard::Base) do
      desc "stubborn", "stubborn"
      def stubborn = sh "trap '' TERM; sleep 30", background: :stubborn, silent: true
    end
    capture_io { klass.new([], {}, {}).invoke(:stubborn) }
    record = state.read_record("stubborn")
    wait_until { `pgrep -g #{record[:pid]}`.split.size >= 3 }
    out, = capture_io { assert_raises(SystemExit) { jobs("stop", "stubborn", "--timeout", "1") }.tap { |e| assert_equal 1, e.status } }
    assert_match(/\Awaiting for stubborn \(pid #{record[:pid]}\)\nkilled stubborn \(pid #{record[:pid]}\) after 1s\n\z/, out)
    refute state.verified?(record)
    out, = capture_io { jobs("list") }
    assert_match(/stubborn\s+│.*│\s+exited 137/, out, "the KILL is in the listing")
  end

  def test_stop_all_covers_every_project_newest_first
    start_servers
    out, = capture_io { jobs("stop", "--all") }
    assert_equal(%w[jobs_test_servers-1 jtdb], out.lines.map { |line| line[/stopped (\S+)/, 1] })
  end

  # J3 (decision D2): the log holds only the latest run, and the help
  # text says so. The behaviour itself is pinned by
  # test_a_new_start_of_an_ended_job_replaces_its_record_and_truncates_the_log.
  def test_regression_j3_log_help_describes_the_latest_run_only
    description = Commands.commands["log"].description
    refute_match(/append/i, description)
    assert_match(/latest run/, description)
  end

  # J8: --all with names is a usage error, not a silent stop of everything.
  def test_regression_j8_stop_all_with_names_is_refused
    _, err = capture_io { assert_raises(SystemExit) { jobs("stop", "--all", "jtdb") } }
    assert_match(/--all takes no job names/, err)
  end

  def test_log_prints_the_log_and_complains_about_unknown_jobs
    records = start_servers
    wait_until { File.exist?(records["jtdb"][:log]) }
    File.write(records["jtdb"][:log], "line one\n")
    out, = capture_io { jobs("log", "jtdb") }
    assert_equal "line one\n", out
    _, err = capture_io { assert_raises(SystemExit) { jobs("log", "nope") } }
    assert_match "no such job: nope", err
    File.delete(records["jtdb"][:log])
    _, err = capture_io { jobs("log", "jtdb") }
    assert_match "jtdb has no log yet", err
  end

  def test_restart_stops_the_job_and_runs_its_task_again
    records = start_servers
    out, = capture_io { jobs("restart", "jtdb") }
    assert_match "stopped jtdb (pid #{records['jtdb'][:pid]})", out
    fresh = state.read_record("jtdb")
    refute_equal records["jtdb"][:pid], fresh[:pid]
    assert state.verified?(fresh)
    state.write_record(fixture("manual", task: ""))
    _, err = capture_io { assert_raises(SystemExit) { jobs("restart", "manual") } }
    assert_match "was not started from a task", err
  end

  def test_clean_forgets_only_what_is_not_running
    records = start_servers
    Asgard::Jobs::Stopper.signal_group("TERM", records["jtdb"][:pgid])
    wait_for_status("jtdb")
    out, = capture_io { jobs("clean") }
    assert_equal "removed jtdb\n", out
    assert_equal(%w[jobs_test_servers-1], state.records.map { |record| record[:name] })
    assert_equal [], Dir.children(state.dir).grep(/\Ajtdb\./), "record, script, status and log all go"
    out, = capture_io { jobs("clean") }
    assert_equal "Nothing to clean for #{@slug}.\n", out
  end
end
