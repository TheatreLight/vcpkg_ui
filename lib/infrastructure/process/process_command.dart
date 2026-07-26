import 'dart:convert';
import 'dart:io';

enum OutputEncodingKind { utf8, system }

final class OutputDecoderPolicy {
  const OutputDecoderPolicy._(this.kind);

  const OutputDecoderPolicy.utf8() : this._(OutputEncodingKind.utf8);

  const OutputDecoderPolicy.system() : this._(OutputEncodingKind.system);

  final OutputEncodingKind kind;

  Stream<String> decode(Stream<List<int>> bytes) => switch (kind) {
    OutputEncodingKind.utf8 => bytes.transform(
      const Utf8Decoder(allowMalformed: true),
    ),
    OutputEncodingKind.system => bytes.transform(
      Platform.isWindows
          ? systemEncoding.decoder
          : const Utf8Decoder(allowMalformed: true),
    ),
  };
}

final class ProcessCommand {
  ProcessCommand({
    required this.executable,
    Iterable<String> arguments = const <String>[],
    required this.workingDirectory,
    Map<String, String> environment = const <String, String>{},
    this.includeParentEnvironment = true,
    this.stdoutDecoder = const OutputDecoderPolicy.utf8(),
    this.stderrDecoder = const OutputDecoderPolicy.utf8(),
  }) : arguments = List<String>.unmodifiable(arguments),
       environment = Map<String, String>.unmodifiable(environment) {
    if (executable.trim().isEmpty) {
      throw ArgumentError.value(executable, 'executable', 'must not be empty');
    }
    if (workingDirectory.trim().isEmpty) {
      throw ArgumentError.value(
        workingDirectory,
        'workingDirectory',
        'must not be empty',
      );
    }
  }

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;
  final bool includeParentEnvironment;
  final OutputDecoderPolicy stdoutDecoder;
  final OutputDecoderPolicy stderrDecoder;

  String get displayName =>
      <String>[executable, ...arguments].map(_quoteForDisplay).join(' ');

  static String _quoteForDisplay(String value) {
    if (!value.contains(RegExp(r'[\s"]'))) {
      return value;
    }
    return '"${value.replaceAll('"', '\\"')}"';
  }
}
