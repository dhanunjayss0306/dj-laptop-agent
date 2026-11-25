// Organize page. Downloads only. Plan then confirm: the plan moves
// nothing until the user says Yes. The confirm dialog shows the judge
// warnings before anything moves.
import 'package:flutter/material.dart';

import '../core/judge.dart';
import '../core/models.dart';
import 'app_state.dart';

/// The five range choices, in order.
const List<(String label, OrganizeRange range)> organizeRanges = [
  ('Today', OrganizeRangeToday()),
  ('Yesterday', OrganizeRangeYesterday()),
  ('Last 3 days', OrganizeRangeLastDays(days: 3)),
  ('Last 7 days', OrganizeRangeLastDays(days: 7)),
  ('All', OrganizeRangeAll()),
];

/// Plan table: File / Move from / Move to / Folder. Shows the first 20
/// moves plus "and N more" when the plan is longer.
class OrganizePlanTable extends StatelessWidget {
  const OrganizePlanTable({super.key, required this.plan});

  final List<OrganizeMove> plan;

  @override
  Widget build(BuildContext context) {
    final shown = plan.take(20).toList();
    final rest = plan.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Table(
          border: TableBorder.all(color: const Color(0xFFE5E5E5)),
          columnWidths: const {
            0: FlexColumnWidth(2),
            1: FlexColumnWidth(3),
            2: FlexColumnWidth(3),
            3: FlexColumnWidth(2),
          },
          children: [
            const TableRow(
              decoration: BoxDecoration(color: Color(0xFFF5F5F7)),
              children: [
                _Cell('File', bold: true),
                _Cell('Move from', bold: true),
                _Cell('Move to', bold: true),
                _Cell('Folder', bold: true),
              ],
            ),
            for (final move in shown)
              TableRow(
                children: [
                  _Cell(move.name),
                  _Cell(move.old),
                  _Cell(move.newPath),
                  _Cell(move.folder),
                ],
              ),
          ],
        ),
        if (rest > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('and $rest more'),
          ),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.text, {this.bold = false});

  final String text;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
    );
  }
}

/// Confirm dialog for applying an organize plan. Shows the judge
/// warnings. Returns true when the user confirms.
Future<bool> showOrganizeConfirm(
  BuildContext context,
  List<OrganizeMove> plan,
) async {
  final judged = judgeAction(JudgeInput(
    kind: 'organize',
    text: 'organize Downloads',
    destructive: true,
    targetCount: plan.length,
  ));
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Move these files?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This will move ${plan.length} file(s) inside Downloads. '
            'Nothing is deleted and nothing is overwritten.',
          ),
          for (final w in judged.warnings) ...[
            const SizedBox(height: 8),
            Text('Note: $w'),
          ],
          for (final b in judged.blocked) ...[
            const SizedBox(height: 8),
            Text('Blocked: $b'),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: judged.blocked.isNotEmpty
              ? null
              : () => Navigator.of(context).pop(true),
          child: const Text('Yes, move them'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

class OrganizePage extends StatefulWidget {
  const OrganizePage({super.key, required this.app});

  final DjAppState app;

  @override
  State<OrganizePage> createState() => _OrganizePageState();
}

class _OrganizePageState extends State<OrganizePage> {
  OrganizeRange? _range;
  ChatResponseOrganizePlan? _plan;
  String? _message;
  String? _result;

  void _pickRange(OrganizeRange range) {
    final response = widget.app.chat.planOrganize(range);
    setState(() {
      _range = range;
      _result = null;
      if (response is ChatResponseOrganizePlan) {
        _plan = response;
        _message = response.text;
      } else {
        _plan = null;
        _message = response.text;
      }
    });
  }

  Future<void> _applyPlan() async {
    final plan = _plan;
    if (plan == null) return;
    final confirmed =
        await showOrganizeConfirm(context, plan.plan);
    if (!confirmed || !mounted) return;
    final done = widget.app.chat.applyOrganize(plan.plan);
    setState(() {
      _plan = null;
      final lines = <String>[done.text];
      if (done is ChatResponseOrganizeDone) lines.addAll(done.errors);
      _result = lines.join('\n');
      _message = null;
    });
  }

  void _cancelPlan() {
    setState(() {
      _plan = null;
      _message = null;
      _result = 'Organize cancelled. Nothing was moved.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Organize Downloads',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text('Only files directly in Downloads are moved.'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, range) in organizeRanges)
                OutlinedButton(
                  onPressed: () => _pickRange(range),
                  style: _range == range
                      ? OutlinedButton.styleFrom(
                          side: const BorderSide(
                              color: Color(0xFF0071E3)),
                          foregroundColor: const Color(0xFF0071E3),
                        )
                      : null,
                  child: Text(label),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_message != null) Text(_message!),
                  if (_plan != null) ...[
                    const SizedBox(height: 12),
                    OrganizePlanTable(plan: _plan!.plan),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        ElevatedButton(
                          onPressed: _applyPlan,
                          child: const Text('Yes, move them'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: _cancelPlan,
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ],
                  if (_result != null) ...[
                    const SizedBox(height: 12),
                    Text(_result!),
                  ],
                  if (_message == null && _plan == null && _result == null)
                    const Text(
                      'Pick a range to see what would move. '
                      'Nothing moves until you say Yes.',
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
