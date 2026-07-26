import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../domain/package_models.dart';
import '../domain/vendor_version_models.dart';
import '../infrastructure/platform/vcpkg_platform_adapter.dart';
import '../infrastructure/process/process_runner.dart';

class PackageCatalogException implements Exception {
  const PackageCatalogException(this.message);

  final String message;

  @override
  String toString() => 'PackageCatalogException: $message';
}

class PackageCatalogService {
  const PackageCatalogService({
    required this.adapter,
    required this.runner,
    required this.layout,
  });

  final VcpkgPlatformAdapter adapter;
  final ProcessRunner runner;
  final VcpkgLayout layout;

  Future<List<PackageViewState>> load() async {
    final results = await Future.wait([
      _loadPortMetadata(),
      _loadInstalledPackages(),
    ]);
    final metadata = results[0] as List<PortMetadata>;
    final installed = results[1] as List<InstalledPackage>;
    final installedByName = <String, List<InstalledPackage>>{};
    for (final package in installed) {
      installedByName
          .putIfAbsent(package.name.toLowerCase(), () => <InstalledPackage>[])
          .add(package);
    }

    final packages = metadata
        .map(
          (port) => PackageViewState(
            metadata: port,
            installed: installedByName[port.name.toLowerCase()] ?? const [],
          ),
        )
        .toList();
    packages.sort(
      (left, right) => left.metadata.name.compareTo(right.metadata.name),
    );
    return List<PackageViewState>.unmodifiable(packages);
  }

  Future<List<InstalledPackage>> refreshInstalled() => _loadInstalledPackages();

  Future<List<PortMetadata>> _loadPortMetadata() async {
    final portsDirectory = Directory(layout.portsDirectory);
    if (!await portsDirectory.exists()) {
      throw PackageCatalogException(
        'Ports directory does not exist: ${layout.portsDirectory}',
      );
    }

    final directories = await portsDirectory
        .list(followLinks: false)
        .where((entity) => entity is Directory)
        .cast<Directory>()
        .toList();
    directories.sort((left, right) => left.path.compareTo(right.path));

    return Future.wait(directories.map(_readPort));
  }

  Future<PortMetadata> _readPort(Directory directory) async {
    final directoryName = directory.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .last;
    final jsonManifest = File(path.join(directory.path, 'vcpkg.json'));
    final controlManifest = File(path.join(directory.path, 'CONTROL'));
    try {
      if (await jsonManifest.exists()) {
        return _parseJsonManifest(
          await jsonManifest.readAsString(),
          jsonManifest.path,
        );
      }
      if (await controlManifest.exists()) {
        return _parseControlManifest(
          await controlManifest.readAsString(),
          controlManifest.path,
        );
      }
      return PortMetadata(
        name: directoryName,
        manifestPath: directory.path,
        metadataError: 'Neither vcpkg.json nor CONTROL exists.',
      );
    } on Object catch (error) {
      return PortMetadata(
        name: directoryName,
        manifestPath: await jsonManifest.exists()
            ? jsonManifest.path
            : controlManifest.path,
        metadataError: error.toString(),
      );
    }
  }

  PortMetadata _parseJsonManifest(String text, String path) {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Manifest root must be a JSON object.');
    }
    final name = decoded['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('Manifest does not contain a package name.');
    }
    final packageName = _normalisePackageName(name, 'Manifest name');
    final manifestVersion = _manifestVersion(decoded);
    final portVersion = _parsePortVersion(decoded['port-version']);
    final availableVersion = _withPortVersion(
      manifestVersion?.value,
      portVersion,
    );
    return PortMetadata(
      name: packageName,
      availableVersion: availableVersion,
      sourceVersion: manifestVersion?.value,
      versionScheme: manifestVersion?.scheme,
      portVersion: portVersion,
      description: _description(decoded['description']),
      manifestPath: path,
    );
  }

  PortMetadata _parseControlManifest(String text, String path) {
    final fields = <String, String>{};
    String? currentField;
    for (final line in text.replaceAll('\r\n', '\n').split('\n')) {
      if (line.trim().isEmpty && fields.containsKey('source')) {
        break;
      }
      final fieldMatch = RegExp(
        r'^([A-Za-z][A-Za-z0-9-]*):\s*(.*)$',
      ).firstMatch(line);
      if (fieldMatch != null) {
        currentField = fieldMatch.group(1)!.toLowerCase();
        fields[currentField] = fieldMatch.group(2)!.trim();
      } else if ((line.startsWith(' ') || line.startsWith('\t')) &&
          currentField != null) {
        fields[currentField] = '${fields[currentField]} ${line.trim()}'.trim();
      }
    }
    final name = fields['source'];
    if (name == null || name.isEmpty) {
      throw const FormatException('CONTROL does not contain Source.');
    }
    final packageName = _normalisePackageName(name, 'CONTROL Source');
    final String? rawVersion = fields['version'] ?? fields['version-string'];
    final int portVersion = _parsePortVersion(fields['port-version']);
    return PortMetadata(
      name: packageName,
      availableVersion: _withPortVersion(rawVersion, portVersion),
      sourceVersion: rawVersion,
      versionScheme: fields.containsKey('version')
          ? VcpkgVersionScheme.relaxed
          : VcpkgVersionScheme.string,
      portVersion: portVersion,
      description: fields['description'],
      manifestPath: path,
    );
  }

  Future<List<InstalledPackage>> _loadInstalledPackages() async {
    final result = await runner.run(
      adapter.listInstalledCommand(layout),
      captureOutput: true,
    );
    if (!result.succeeded) {
      throw PackageCatalogException(
        'vcpkg list failed with exit code ${result.exitCode}.',
      );
    }
    return parseInstalledJson(result.capturedStdout);
  }

  List<InstalledPackage> parseInstalledJson(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw PackageCatalogException(
        'vcpkg list returned invalid JSON: ${error.message}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const PackageCatalogException(
        'vcpkg list JSON root is not an object.',
      );
    }

    final result = <InstalledPackage>[];
    for (final entry in decoded.entries) {
      if (entry.value is! Map<String, dynamic>) {
        continue;
      }
      final value = entry.value as Map<String, dynamic>;
      final keyParts = entry.key.split(':');
      final name = value['package_name'] is String
          ? value['package_name'] as String
          : keyParts.first;
      final triplet = value['triplet'] is String
          ? value['triplet'] as String
          : (keyParts.length > 1 ? keyParts.last : 'unknown');
      final rawVersion = value['version']?.toString() ?? 'unknown';
      final version = _withPortVersion(rawVersion, value['port_version'])!;
      final features = value['features'] is List
          ? (value['features'] as List).whereType<String>().toList(
              growable: false,
            )
          : const <String>[];
      result.add(
        InstalledPackage(
          name: name,
          triplet: triplet,
          version: version,
          features: features,
        ),
      );
    }
    result.sort((left, right) => left.key.compareTo(right.key));
    return result;
  }

  ({String value, VcpkgVersionScheme scheme})? _manifestVersion(
    Map<String, dynamic> source,
  ) {
    const schemes = <String, VcpkgVersionScheme>{
      'version': VcpkgVersionScheme.relaxed,
      'version-semver': VcpkgVersionScheme.semver,
      'version-date': VcpkgVersionScheme.date,
      'version-string': VcpkgVersionScheme.string,
    };
    for (final entry in schemes.entries) {
      final value = source[entry.key];
      if (value is String && value.isNotEmpty) {
        return (value: value, scheme: entry.value);
      }
    }
    return null;
  }

  String _normalisePackageName(String value, String field) {
    final packageName = value.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9][a-z0-9+_.-]*$').hasMatch(packageName)) {
      throw FormatException(
        '$field contains an unsafe vcpkg package name: $value',
      );
    }
    return packageName;
  }

  String? _withPortVersion(Object? version, Object? rawPortVersion) {
    if (version == null) {
      return null;
    }
    final value = version.toString();
    final portVersion = _parsePortVersion(rawPortVersion);
    return portVersion > 0 ? '$value#$portVersion' : value;
  }

  int _parsePortVersion(Object? rawPortVersion) => switch (rawPortVersion) {
    int number => number,
    String text => int.tryParse(text) ?? 0,
    _ => 0,
  };

  String? _description(Object? value) => switch (value) {
    String text => text.trim().isEmpty ? null : text.trim(),
    List items => items.whereType<String>().join('\n').trim(),
    _ => null,
  };
}
