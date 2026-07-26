import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vcpkg_ui/domain/output_models.dart';
import 'package:vcpkg_ui/infrastructure/logging/log_store.dart';
import 'package:vcpkg_ui/infrastructure/process/process_command.dart';

typedef OutputLineCallback = void Function(OutputLine line);

final class ProcessRunResult {
  const ProcessRunResult({
    required this.command,
    required this.started,
    required this.exitCode,
    required this.capturedStdout,
    required this.capturedStderr,
    required this.logPath,
    required this.duration,
    this.errorMessage,
  });

  final ProcessCommand command;
  final bool started;
  final int? exitCode;
  final String capturedStdout;
  final String capturedStderr;
  final String? logPath;
  final Duration duration;
  final String? errorMessage;

  bool get succeeded => started && exitCode == 0 && errorMessage == null;
}

final class ProcessRunner {
  const ProcessRunner();

  Future<ProcessRunResult> run(
    ProcessCommand command, {
    OperationLog? log,
    OutputLineCallback? onOutput,
    bool captureOutput = false,
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    final StringBuffer stdoutCapture = StringBuffer();
    final StringBuffer stderrCapture = StringBuffer();
    String? processingError;
    Process process;

    try {
      process = await Process.start(
        command.executable,
        command.arguments,
        workingDirectory: command.workingDirectory,
        environment: command.environment,
        includeParentEnvironment: command.includeParentEnvironment,
        runInShell: false,
      );
    } on Object catch (error) {
      processingError = error.toString();
      final OutputLine line = OutputLine(
        source: OutputSource.system,
        text: 'Failed to start process: $error',
        timestamp: DateTime.now(),
      );
      processingError = _emit(line, log, onOutput, processingError);
      processingError = await _closeLog(log, processingError);
      stopwatch.stop();
      return ProcessRunResult(
        command: command,
        started: false,
        exitCode: null,
        capturedStdout: '',
        capturedStderr: '',
        logPath: log?.path,
        duration: stopwatch.elapsed,
        errorMessage: processingError,
      );
    }

    final _MutableError streamError = _MutableError();
    final Future<void> stdoutDone = _consume(
      command.stdoutDecoder.decode(process.stdout),
      OutputSource.stdout,
      log,
      onOutput,
      captureOutput ? stdoutCapture : null,
      streamError,
    );
    final Future<void> stderrDone = _consume(
      command.stderrDecoder.decode(process.stderr),
      OutputSource.stderr,
      log,
      onOutput,
      captureOutput ? stderrCapture : null,
      streamError,
    );

    int? exitCode;
    try {
      exitCode = await process.exitCode;
    } on Object catch (error) {
      processingError = error.toString();
    }

    // A process exit does not imply that the pipe buffers have reached EOF.
    // Awaiting both consumers also flushes the streaming decoders, including a
    // final line without a newline.
    await Future.wait<void>(<Future<void>>[stdoutDone, stderrDone]);
    processingError ??= streamError.value;
    processingError = await _closeLog(log, processingError);
    stopwatch.stop();

    return ProcessRunResult(
      command: command,
      started: true,
      exitCode: exitCode,
      capturedStdout: stdoutCapture.toString(),
      capturedStderr: stderrCapture.toString(),
      logPath: log?.path,
      duration: stopwatch.elapsed,
      errorMessage: processingError,
    );
  }

  Future<void> _consume(
    Stream<String> decoded,
    OutputSource source,
    OperationLog? log,
    OutputLineCallback? callback,
    StringBuffer? capture,
    _MutableError error,
  ) async {
    try {
      await for (final String rawLine in decoded.transform(
        const LineSplitter(),
      )) {
        final String text = stripAnsiSequences(rawLine);
        final OutputLine line = OutputLine(
          source: source,
          text: text,
          timestamp: DateTime.now(),
        );
        if (capture != null) {
          if (capture.isNotEmpty) {
            capture.writeln();
          }
          capture.write(text);
        }
        error.value = _emit(line, log, callback, error.value);
      }
    } on Object catch (caught) {
      error.value ??= caught.toString();
    }
  }

  static String? _emit(
    OutputLine line,
    OperationLog? log,
    OutputLineCallback? callback,
    String? previousError,
  ) {
    String? error = previousError;
    try {
      log?.write(line);
    } on Object catch (caught) {
      error ??= caught.toString();
    }
    try {
      callback?.call(line);
    } on Object catch (caught) {
      error ??= caught.toString();
    }
    return error;
  }

  static Future<String?> _closeLog(
    OperationLog? log,
    String? previousError,
  ) async {
    try {
      await log?.close();
      return previousError;
    } on Object catch (error) {
      return previousError ?? error.toString();
    }
  }
}

final class _MutableError {
  String? value;
}

String stripAnsiSequences(String value) => value.replaceAll(
  RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))'),
  '',
);
