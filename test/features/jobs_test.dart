// JobManager tests: parallel jobs, cancel, failure. Runners are
// fakes — no AgentMode, no network.


import 'package:dj/features/agent_mode.dart';
import 'package:dj/features/jobs.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitUntil(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) {
      throw StateError('timed out waiting for jobs');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

AgentTaskResult doneResult(String answer) =>
    AgentTaskResult(done: true, stepsTaken: 1, answer: answer);

void main() {
  test('three jobs run in parallel and all finish', () async {
    final manager = JobManager();
    Future<AgentTaskResult> slow(String task) async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      return doneResult('done: $task');
    }

    final ids = [
      manager.startJob('job one', 'task one', runner: slow),
      manager.startJob('job two', 'task two', runner: slow),
      manager.startJob('job three', 'task three', runner: slow),
    ];
    // All three are running at once, not one after another.
    expect(
      manager.listJobs().map((j) => j.status),
      everyElement(isNot(JobStatus.done)),
    );
    await waitUntil(
      () => manager
          .listJobs()
          .every((j) => j.status == JobStatus.done),
    );
    final jobs = manager.listJobs();
    expect(jobs.map((j) => j.id), ids);
    expect(jobs.map((j) => j.result), [
      'done: task one',
      'done: task two',
      'done: task three',
    ]);
    // A job never blocks another job: total time is ~one slow job,
    // not three in a row. (Checked by the wait above finishing fast;
    // the 5s timeout would have failed on serial 180ms+ runs too, so
    // this is a weak check — the real proof is all three queued at once.)
    manager.dispose();
  });

  test('job updates stream reports start and finish', () async {
    final manager = JobManager();
    final seen = <JobStatus>[];
    final sub = manager.updates.listen((u) => seen.add(u.job.status));
    manager.startJob(
      'stream job',
      'do it',
      runner: (_) async => doneResult('ok'),
    );
    await waitUntil(
      () => manager.listJobs().first.status == JobStatus.done,
    );
    await Future<void>.delayed(Duration.zero);
    expect(seen, contains(JobStatus.queued));
    expect(seen, contains(JobStatus.running));
    expect(seen, contains(JobStatus.done));
    await sub.cancel();
    manager.dispose();
  });

  test('cancelJob before start stops the job and the runner never runs', () async {
    final manager = JobManager();
    var ran = false;
    final id = manager.startJob(
      'cancel me',
      'slow task',
      runner: (_) async {
        ran = true;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return doneResult('should not happen');
      },
    );
    expect(manager.cancelJob(id), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final job = manager.job(id)!;
    expect(job.status, JobStatus.cancelled);
    expect(ran, isFalse);
    manager.dispose();
  });

  test('cancelJob on an unknown id returns false', () {
    final manager = JobManager();
    expect(manager.cancelJob('job-999'), isFalse);
    manager.dispose();
  });

  test('a failing runner marks the job failed, not the manager', () async {
    final manager = JobManager();
    final badId = manager.startJob(
      'bad job',
      'fail',
      runner: (_) async => const AgentTaskResult(
        done: false,
        stepsTaken: 2,
        answer: '',
        stoppedReason: 'stuck: same action 3 times',
      ),
    );
    final goodId = manager.startJob(
      'good job',
      'ok',
      runner: (_) async => doneResult('fine'),
    );
    await waitUntil(
      () =>
          manager.job(badId)!.status == JobStatus.failed &&
          manager.job(goodId)!.status == JobStatus.done,
    );
    expect(manager.job(badId)!.error, contains('same action 3 times'));
    expect(manager.job(goodId)!.result, 'fine');
    manager.dispose();
  });

  test('a throwing runner marks the job failed', () async {
    final manager = JobManager();
    final id = manager.startJob(
      'boom',
      'boom',
      runner: (_) async => throw StateError('kaboom'),
    );
    await waitUntil(() => manager.job(id)!.status == JobStatus.failed);
    expect(manager.job(id)!.error, contains('kaboom'));
    manager.dispose();
  });

  test('listJobs returns jobs oldest first', () async {
    final manager = JobManager();
    final first = manager.startJob('first', 'a', runner: (_) async => doneResult('a'));
    final second = manager.startJob('second', 'b', runner: (_) async => doneResult('b'));
    expect(manager.listJobs().map((j) => j.id), [first, second]);
    manager.dispose();
  });
}
