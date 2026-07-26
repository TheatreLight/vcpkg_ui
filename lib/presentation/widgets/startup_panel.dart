import 'package:flutter/material.dart';

class StartupProgressPanel extends StatelessWidget {
  const StartupProgressPanel({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 20),
          Text(message, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

class StartupDiagnosticPanel extends StatelessWidget {
  const StartupDiagnosticPanel({
    super.key,
    required this.rawRoot,
    required this.reason,
  });

  final String? rawRoot;
  final String reason;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.error_outline,
                      color: Theme.of(context).colorScheme.error,
                      size: 30,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'VCPKG_ROOT is not ready',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Text('Environment value'),
                const SizedBox(height: 4),
                SelectableText(
                  rawRoot ?? '<not set>',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 16),
                const Text('Reason'),
                const SizedBox(height: 4),
                SelectableText(reason),
                const SizedBox(height: 20),
                Text(
                  'Set or correct the system environment variable, then '
                  'restart this application.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
