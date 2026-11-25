// JobManager — run MANY agent jobs at once.
//
// Each job: {id, title, status (queued/running/done/failed/cancelled),
// progress, result, error}. The UI listens to [updates] and lists jobs
// with [listJobs]. A job never blocks another job.
//
// v1 NOTE: jobs run as Dart async tasks (Futures) on the same isolate.
// That is enough for agent jobs, which spend most of their time
// waiting on tools and the model. True isolates (one isolate per job)
// are a future step — they are not needed until a job does heavy
// CPU work on its own. This comment is the honest record of that.
//
// Cancellation is cooperative: [cancelJob] marks the job cancelled.
// A job that has not started its runner yet never starts; a running
// job is marked cancelled when its runner returns (the runner itself
// is not killed mid-flight — killing a tool mid-click would be worse
// than letting it finish the step).

import 'dart:async';

import 'agent_mode.dart';

enum JobStatus { queued, running, done, failed, cancelled }

/// One job.
class Job {
  Job({
    required this.id,
    required this.title,
    required this.status,
    this.progress = 0,
    this.result,
    this.error,
  });
  final String id;
  final String title;
  JobStatus status;
  double progress;
  String? result;
  String? error;
}

/// One update on the [JobManager.updates] stream.
class JobUpdate {
  const JobUpdate({required this.jobId, required this.job});
  final String jobId;
  final Job job;
}

class JobManager {
  JobManager({this.agentMode});

  /// AgentMode used to run jobs. When null, [startJob] needs a
  /// [runner] passed in; with neither, the job fails plainly.
  final AgentMode? agentMode;

  final Map<String, Job> _jobs = {};
  final Map<String, bool> _cancelRequested = {};
  final _updates = StreamController<JobUpdate>.broadcast();

  /// Every job change (started, progress, finished, cancelled).
  Stream<JobUpdate> get updates => _updates.stream;

  int _nextId = 1;

  /// All jobs, oldest first.
  List<Job> listJobs() => _jobs.values.toList();

  Job? job(String id) => _jobs[id];

  /// Start a job and return its id at once. The job runs in the
  /// background; listen to [updates] for its progress.
  ///
  /// [runner] overrides [agentMode] for this job (tests use this).
  /// It receives the task text and returns the agent result.
  String startJob(
    String title,
    String task, {
    Future<AgentTaskResult> Function(String task)? runner,
  }) {
    final id = 'job-${_nextId++}';
    final job = Job(id: id, title: title, status: JobStatus.queued);
    _jobs[id] = job;
    _cancelRequested[id] = false;
    _emit(job);
    unawaited(_run(id, task, runner));
    return id;
  }

  /// Ask a job to stop. Returns false when the id is unknown.
  /// A queued job never starts; a running job is marked cancelled
  /// when its current step finishes.
  bool cancelJob(String id) {
    final job = _jobs[id];
    if (job == null) return false;
    if (job.status == JobStatus.done ||
        job.status == JobStatus.failed ||
        job.status == JobStatus.cancelled) {
      return false;
    }
    _cancelRequested[id] = true;
    if (job.status == JobStatus.queued) {
      job.status = JobStatus.cancelled;
      job.error = 'Cancelled before it started.';
      _emit(job);
    }
    return true;
  }

  Future<void> _run(
    String id,
    String task,
    Future<AgentTaskResult> Function(String task)? runner,
  ) async {
    final job = _jobs[id];
    if (job == null) return;
    // Give cancelJob a chance to land before the runner starts.
    await Future<void>.delayed(Duration.zero);
    if (_cancelRequested[id] == true) {
      job.status = JobStatus.cancelled;
      job.error ??= 'Cancelled.';
      _emit(job);
      return;
    }
    job.status = JobStatus.running;
    job.progress = 0.05;
    _emit(job);

    final run = runner ?? _defaultRunner;
    if (run == null) {
      job.status = JobStatus.failed;
      job.error = 'No agent runner configured for this job.';
      _emit(job);
      return;
    }
    try {
      final result = await run(task);
      if (_cancelRequested[id] == true) {
        job.status = JobStatus.cancelled;
        job.error = 'Cancelled.';
      } else if (result.done) {
        job.status = JobStatus.done;
        job.progress = 1;
        job.result = result.answer;
      } else {
        job.status = JobStatus.failed;
        job.progress = 1;
        job.error =
            result.stoppedReason ?? result.error ?? 'Job did not finish.';
      }
    } catch (e) {
      if (_cancelRequested[id] == true) {
        job.status = JobStatus.cancelled;
        job.error = 'Cancelled.';
      } else {
        job.status = JobStatus.failed;
        job.error = 'Job failed: $e';
      }
    }
    _emit(job);
  }

  Future<AgentTaskResult> Function(String task)? get _defaultRunner {
    final mode = agentMode;
    if (mode == null) return null;
    return (String task) async {
      final result = await mode.run(task);
      return result;
    };
  }

  void _emit(Job job) {
    _updates.add(JobUpdate(jobId: job.id, job: job));
  }

  void dispose() => _updates.close();
}

void unawaited(Future<void> f) {}
