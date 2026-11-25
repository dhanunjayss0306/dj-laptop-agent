// Judge before acting. Port of src/main/v53/judge.ts.
// Score S = 0.7*G (goal completion) + 0.3*E (delivery), out of 5.
// A destructive action always needs a human confirm, even at 5/5.
// Nothing auto-deletes, nothing auto-sends.

typedef JudgeTarget = String; // 'reply'|'delete'|'merge'|'send'|'organize'|'open'

class JudgeInput {
  final String kind;
  final String text;
  final bool destructive;
  final int? targetCount;
  final String? goal;
  const JudgeInput({
    required this.kind,
    required this.text,
    required this.destructive,
    this.targetCount,
    this.goal,
  });
}

class JudgeResult {
  final double score;
  final List<String> blocked;
  final List<String> warnings;
  final bool needsConfirm;
  const JudgeResult({
    required this.score,
    required this.blocked,
    required this.warnings,
    required this.needsConfirm,
  });
}

JudgeResult judgeAction(JudgeInput input) {
  final blocked = <String>[];
  final warnings = <String>[];
  final text = input.text.trim();

  // Goal completion (G): is the ask clear and targetable?
  var goalScore = 5.0;
  if (text.isEmpty) {
    goalScore = 0;
    blocked.add('nothing to act on');
  }
  if (input.destructive && (input.targetCount ?? 0) == 0) {
    goalScore = 0;
    blocked.add('no target named — nothing would be touched, so nothing runs');
  }
  if (input.destructive &&
      input.targetCount != null &&
      input.targetCount! > 50) {
    goalScore = 2;
    warnings.add(
        'this would touch ${input.targetCount} files — check the list first');
  }
  if (input.goal != null &&
      !text
          .toLowerCase()
          .contains(input.goal!.toLowerCase().substring(
              0, input.goal!.length < 12 ? input.goal!.length : 12))) {
    goalScore = goalScore < 3 ? goalScore : 3;
    warnings.add('the plan does not clearly match the goal you stated');
  }

  // Delivery (E): is the plan safe to show and run?
  var deliveryScore = 5.0;
  if (input.destructive) {
    deliveryScore = 4;
    warnings.add('destructive: needs your confirm before anything runs');
  }
  if (input.kind == 'send') {
    deliveryScore = 3;
    warnings.add('sending is always manual — DJ drafts, you press send');
  }

  final score = ((0.7 * goalScore + 0.3 * deliveryScore) * 10).round() / 10;
  return JudgeResult(
    score: score,
    blocked: blocked,
    warnings: warnings,
    needsConfirm:
        input.destructive || input.kind == 'send' || blocked.isNotEmpty,
  );
}
