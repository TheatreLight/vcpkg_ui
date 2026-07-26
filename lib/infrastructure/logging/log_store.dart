import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/domain/operation_models.dart';
import 'package:vcpkg_ui/domain/output_models.dart';

abstract interface class OperationLog {
  String get path;

  void write(OutputLine line);

  Future<void> close();
}

final class LogStore {
  LogStore(this.directoryPath);

  final String directoryPath;

  Future<OperationLog> create(OperationKind operation) async {
    final Directory directory = Directory(directoryPath);
    await directory.create(recursive: true);

    final DateTime now = DateTime.now().toUtc();
    final String stamp = now
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .replaceAll('Z', '');
    final String fileName =
        '${stamp}_${now.microsecondsSinceEpoch}_${operation.name}.log';
    final File file = File(path.join(directory.path, fileName));
    return FileOperationLog(
      file.path,
      file.openWrite(mode: FileMode.writeOnly),
    );
  }
}

final class FileOperationLog implements OperationLog {
  FileOperationLog(this.path, this._sink);

  @override
  final String path;

  final IOSink _sink;
  bool _closed = false;

  @override
  void write(OutputLine line) {
    if (_closed) {
      throw StateError('The operation log is already closed.');
    }
    _sink.writeln(
      '${line.timestamp.toUtc().toIso8601String()} ${line.displayText}',
    );
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _sink.flush();
    await _sink.close();
  }
}
