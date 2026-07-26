enum OutputSource { stdout, stderr, system }

final class OutputLine {
  const OutputLine({
    required this.source,
    required this.text,
    required this.timestamp,
  });

  final OutputSource source;
  final String text;
  final DateTime timestamp;

  String get sourceLabel => switch (source) {
    OutputSource.stdout => 'stdout',
    OutputSource.stderr => 'stderr',
    OutputSource.system => 'system',
  };

  String get displayText => '[$sourceLabel] $text';
}
