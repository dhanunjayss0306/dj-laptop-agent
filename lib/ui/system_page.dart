// System page: CPU, cores, RAM, uptime, platform. Each row is labelled
// with its source. CPU null is shown as not measured, never invented.
// No disk usage row.
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services/system_stats.dart';
import 'app_state.dart';
import 'file_type.dart';

class SystemPage extends StatefulWidget {
  const SystemPage({super.key, required this.app});

  final DjAppState app;

  @override
  State<SystemPage> createState() => _SystemPageState();
}

class _SystemPageState extends State<SystemPage> {
  SystemStats? _stats;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stats = await widget.app.systemOps
          .getSystemStats()
          .timeout(const Duration(seconds: 4));
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loading = false;
      });
    } catch (_) {
      // Platform channel unavailable (for example on Linux dev runs):
      // fall back to the local /proc reader. It returns null CPU on
      // non-Linux platforms, which the UI reports as not measured.
      try {
        final stats = await readSystemStats();
        if (!mounted) return;
        setState(() {
          _stats = stats;
          _loading = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _error = 'Could not read system stats: $e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final cpuSource = Platform.isWindows
        ? 'Source: Windows system stats'
        : 'Source: /proc/stat (Linux)';
    final memSource = Platform.isWindows
        ? 'Source: Windows system stats'
        : 'Source: /proc/meminfo (Linux)';
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'System',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Expanded(child: _SystemSkeleton())
          else if (_error != null)
            Expanded(
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _load,
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else if (stats != null)
            Expanded(
              child: ListView(
                children: [
                  _statRow(
                    label: 'CPU use',
                    value: stats.cpuPercent == null
                        ? 'CPU use could not be measured on this device.'
                        : '${stats.cpuPercent!.toStringAsFixed(1)}%',
                    source: cpuSource,
                  ),
                  _statRow(
                    label: 'CPU cores',
                    value: '${stats.cpuCores}',
                    source: cpuSource,
                  ),
                  _statRow(
                    label: 'RAM used',
                    value: stats.totalMemBytes <= 0
                        ? 'Memory could not be measured on this device.'
                        : '${formatBytes(stats.totalMemBytes - stats.freeMemBytes)} '
                            'of ${formatBytes(stats.totalMemBytes)} '
                            '(${((stats.totalMemBytes - stats.freeMemBytes) / stats.totalMemBytes * 100).toStringAsFixed(1)}%)',
                    source: memSource,
                  ),
                  _statRow(
                    label: 'Uptime',
                    value: stats.uptimeSeconds <= 0
                        ? 'Uptime could not be measured on this device.'
                        : formatUptime(stats.uptimeSeconds),
                    source: 'Source: system uptime',
                  ),
                  _statRow(
                    label: 'Platform',
                    value: stats.platform,
                    source: 'Source: Dart Platform',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _statRow({
    required String label,
    required String value,
    required String source,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(value),
            const SizedBox(height: 4),
            Text(source, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _SystemSkeleton extends StatelessWidget {
  const _SystemSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: 5,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, _) => Container(
        height: 72,
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE5E5E5)),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}
