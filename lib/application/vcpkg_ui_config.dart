import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/application/jsonc_parser.dart';

final class VcpkgUiConfigException implements Exception {
  const VcpkgUiConfigException(this.message);

  final String message;

  @override
  String toString() => 'VcpkgUiConfigException: $message';
}

final class VcpkgUiConfiguration {
  const VcpkgUiConfiguration({
    required this.fullInstallScriptPath,
    required this.removeAllScriptPath,
  });

  final String fullInstallScriptPath;
  final String removeAllScriptPath;
}

final class VcpkgUiConfigLoader {
  const VcpkgUiConfigLoader(this.filePath);

  final String filePath;

  VcpkgUiConfiguration loadSync() {
    final File file = File(filePath);
    if (!file.existsSync()) {
      throw VcpkgUiConfigException(
        'Application config does not exist: $filePath. Copy '
        'config/vcpkg-ui.example.jsonc to config/vcpkg-ui.jsonc and edit it.',
      );
    }

    final Object? decoded;
    try {
      decoded = decodeJsonc(file.readAsStringSync());
    } on Object catch (error) {
      throw VcpkgUiConfigException('Could not parse $filePath: $error');
    }
    if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) {
      throw VcpkgUiConfigException(
        '$filePath must be a JSONC object with schema 1.',
      );
    }
    final Object? scripts = decoded['scripts'];
    if (scripts is! Map<String, dynamic>) {
      throw VcpkgUiConfigException('$filePath must contain a scripts object.');
    }
    return VcpkgUiConfiguration(
      fullInstallScriptPath: _requiredPath(scripts, 'fullInstall'),
      removeAllScriptPath: _requiredPath(scripts, 'removeAll'),
    );
  }

  String _requiredPath(Map<String, dynamic> values, String field) {
    final Object? value = values[field];
    if (value is! String || value.trim().isEmpty || value.contains('\u0000')) {
      throw VcpkgUiConfigException(
        '$filePath scripts.$field must be a non-empty path string.',
      );
    }
    return value.trim();
  }

  static String locate({
    Map<String, String> environment = const <String, String>{},
    String? currentDirectory,
    String? executablePath,
  }) {
    final String? explicit = environment['VCPKG_UI_CONFIG']?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return path.normalize(path.absolute(explicit));
    }
    const String relative = 'config/vcpkg-ui.jsonc';
    final List<String> roots = <String>[
      currentDirectory ?? Directory.current.path,
      path.dirname(executablePath ?? Platform.resolvedExecutable),
    ];
    for (final String root in roots) {
      var candidateRoot = path.normalize(path.absolute(root));
      for (var depth = 0; depth < 7; depth++) {
        final String candidate = path.join(candidateRoot, relative);
        if (File(candidate).existsSync()) {
          return candidate;
        }
        final String parent = path.dirname(candidateRoot);
        if (parent == candidateRoot) {
          break;
        }
        candidateRoot = parent;
      }
    }
    return path.normalize(path.absolute(path.join(roots.first, relative)));
  }
}
