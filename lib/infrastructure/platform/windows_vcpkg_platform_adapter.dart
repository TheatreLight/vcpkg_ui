import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/application/vcpkg_ui_config.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/infrastructure/platform/vcpkg_platform_adapter.dart';
import 'package:vcpkg_ui/infrastructure/process/process_command.dart';

final class WindowsVcpkgPlatformAdapter implements VcpkgPlatformAdapter {
  WindowsVcpkgPlatformAdapter({
    Map<String, String>? environment,
    VcpkgUiConfiguration? configuration,
    VcpkgUiConfigLoader? configurationLoader,
  }) : assert(configuration != null || configurationLoader != null),
       _environment = Map<String, String>.unmodifiable(
         environment ?? Platform.environment,
       ),
       _providedConfiguration = configuration,
       _configurationLoader = configurationLoader;

  static final path.Context _windowsPath = path.Context(
    style: path.Style.windows,
  );

  final Map<String, String> _environment;
  final VcpkgUiConfiguration? _providedConfiguration;
  final VcpkgUiConfigLoader? _configurationLoader;

  @override
  String get platformId => 'windows';

  String get _systemRoot =>
      _environment['SystemRoot'] ?? _environment['SYSTEMROOT'] ?? r'C:\Windows';

  String get _cmdPath => _windowsPath.join(_systemRoot, 'System32', 'cmd.exe');

  String get _explorerPath => _windowsPath.join(_systemRoot, 'explorer.exe');

  @override
  VcpkgLayout createLayout(String rawRoot) {
    final String trimmedRoot = rawRoot.trim();
    if (trimmedRoot.isEmpty) {
      throw ArgumentError.value(rawRoot, 'rawRoot', 'must not be empty');
    }

    final String root = _windowsPath.normalize(
      _windowsPath.absolute(trimmedRoot),
    );
    final VcpkgUiConfiguration configuration =
        _providedConfiguration ?? _configurationLoader!.loadSync();
    return VcpkgLayout(
      rootDirectory: root,
      rootMarkerPath: _windowsPath.join(root, '.vcpkg-root'),
      portsDirectory: _windowsPath.join(root, 'ports'),
      executablePath: _windowsPath.join(root, 'vcpkg.exe'),
      removeAllScriptPath: _resolveConfiguredPath(
        root,
        configuration.removeAllScriptPath,
      ),
      fullInstallScriptPath: _resolveConfiguredPath(
        root,
        configuration.fullInstallScriptPath,
      ),
    );
  }

  String _resolveConfiguredPath(String root, String configuredPath) =>
      _windowsPath.normalize(
        _windowsPath.isAbsolute(configuredPath)
            ? configuredPath
            : _windowsPath.join(root, configuredPath),
      );

  @override
  List<RequiredArtifact> requiredArtifacts(VcpkgLayout layout) =>
      <RequiredArtifact>[
        RequiredArtifact(
          code: 'root_directory_missing',
          path: layout.rootDirectory,
          kind: ArtifactKind.directory,
          description: 'VCPKG_ROOT directory',
        ),
        RequiredArtifact(
          code: 'root_marker_missing',
          path: layout.rootMarkerPath,
          kind: ArtifactKind.file,
          description: '.vcpkg-root marker',
        ),
        RequiredArtifact(
          code: 'ports_directory_missing',
          path: layout.portsDirectory,
          kind: ArtifactKind.directory,
          description: 'ports directory',
        ),
        RequiredArtifact(
          code: 'vcpkg_executable_missing',
          path: layout.executablePath,
          kind: ArtifactKind.file,
          description: 'vcpkg executable',
        ),
        RequiredArtifact(
          code: 'remove_all_script_missing',
          path: layout.removeAllScriptPath,
          kind: ArtifactKind.file,
          description: 'remove-all script',
        ),
        RequiredArtifact(
          code: 'full_install_script_missing',
          path: layout.fullInstallScriptPath,
          kind: ArtifactKind.file,
          description: 'full-install script',
        ),
        RequiredArtifact(
          code: 'command_shell_missing',
          path: _cmdPath,
          kind: ArtifactKind.file,
          description: 'Windows command shell',
        ),
      ];

  @override
  List<ValidationIssue> validateLayout(VcpkgLayout layout) {
    final List<ValidationIssue> issues = <ValidationIssue>[];
    for (final RequiredArtifact artifact in requiredArtifacts(layout)) {
      final FileSystemEntityType actualType = FileSystemEntity.typeSync(
        artifact.path,
        followLinks: true,
      );
      final bool valid = switch (artifact.kind) {
        ArtifactKind.file => actualType == FileSystemEntityType.file,
        ArtifactKind.directory => actualType == FileSystemEntityType.directory,
      };
      if (!valid) {
        issues.add(
          ValidationIssue(
            code: artifact.code,
            path: artifact.path,
            message: '${artifact.description} was not found: ${artifact.path}',
          ),
        );
      }
    }
    return issues;
  }

  @override
  String defaultTriplet(Map<String, String> environment) {
    final String? configuredTriplet =
        environment['VCPKG_DEFAULT_TRIPLET'] ??
        _environment['VCPKG_DEFAULT_TRIPLET'];
    if (configuredTriplet != null && configuredTriplet.trim().isNotEmpty) {
      return _validateTriplet(configuredTriplet);
    }

    final String architecture =
        (environment['PROCESSOR_ARCHITEW6432'] ??
                environment['PROCESSOR_ARCHITECTURE'] ??
                _environment['PROCESSOR_ARCHITEW6432'] ??
                _environment['PROCESSOR_ARCHITECTURE'] ??
                'AMD64')
            .toUpperCase();
    if (architecture.contains('ARM64')) {
      return 'arm64-windows';
    }
    if (architecture == 'X86' || architecture.contains('I386')) {
      return 'x86-windows';
    }
    return 'x64-windows';
  }

  @override
  ProcessCommand listInstalledCommand(VcpkgLayout layout) => _vcpkgCommand(
    layout,
    const <String>['list', '--x-json'],
    jsonOutput: true,
  );

  @override
  ProcessCommand packageInfoCommand(VcpkgLayout layout, String packageName) {
    final String validatedName = _validatePackageName(packageName);
    return _vcpkgCommand(layout, <String>[
      'x-package-info',
      validatedName,
      '--x-json',
    ], jsonOutput: true);
  }

  @override
  ProcessCommand installCommand(
    VcpkgLayout layout,
    PackageSpec specification,
  ) => _vcpkgCommand(layout, <String>[
    'install',
    specification.vcpkgArgument,
    '--disable-metrics',
  ]);

  @override
  ProcessCommand removePreviewCommand(
    VcpkgLayout layout,
    PackageSpec specification,
  ) => _vcpkgCommand(layout, <String>[
    'remove',
    specification.vcpkgArgument,
    '--dry-run',
  ]);

  @override
  ProcessCommand removeCommand(
    VcpkgLayout layout,
    PackageSpec specification, {
    required bool recurse,
  }) {
    final List<String> arguments = <String>[
      'remove',
      specification.vcpkgArgument,
    ];
    if (recurse) {
      arguments.add('--recurse');
    }
    return _vcpkgCommand(layout, arguments);
  }

  @override
  ProcessCommand removeAllCommand(VcpkgLayout layout) => ProcessCommand(
    executable: _cmdPath,
    arguments: <String>['/d', '/s', '/c', 'call', layout.removeAllScriptPath],
    workingDirectory: layout.rootDirectory,
    environment: <String, String>{'VCPKG_ROOT': layout.rootDirectory},
    stdoutDecoder: const OutputDecoderPolicy.system(),
    stderrDecoder: const OutputDecoderPolicy.system(),
  );

  @override
  ProcessCommand upgradePreviewCommand(VcpkgLayout layout) =>
      _vcpkgCommand(layout, const <String>['upgrade']);

  @override
  ProcessCommand upgradeAllCommand(VcpkgLayout layout) =>
      _vcpkgCommand(layout, const <String>['upgrade', '--no-dry-run']);

  @override
  ProcessCommand fullInstallCommand(VcpkgLayout layout) => ProcessCommand(
    executable: _cmdPath,
    arguments: <String>['/d', '/s', '/c', 'call', layout.fullInstallScriptPath],
    workingDirectory: layout.rootDirectory,
    environment: <String, String>{'VCPKG_ROOT': layout.rootDirectory},
    stdoutDecoder: const OutputDecoderPolicy.system(),
    stderrDecoder: const OutputDecoderPolicy.system(),
  );

  @override
  String logDirectoryPath(
    Map<String, String> environment, {
    VcpkgLayout? layout,
  }) {
    final Iterable<String> bases = <String?>[
      environment['LOCALAPPDATA'],
      _environment['LOCALAPPDATA'],
      environment['APPDATA'],
      _environment['APPDATA'],
      Directory.systemTemp.path,
    ].whereType<String>();

    for (final String base in bases) {
      final String candidate = _windowsPath.normalize(
        _windowsPath.absolute(_windowsPath.join(base, 'VcpkgUI', 'logs')),
      );
      if (layout == null || !_isInside(candidate, layout.rootDirectory)) {
        return candidate;
      }
    }
    throw StateError('No log directory is available outside VCPKG_ROOT.');
  }

  @override
  Future<void> openLogFile(String filePath) async {
    final String normalisedPath = _windowsPath.normalize(
      _windowsPath.absolute(filePath),
    );
    if (FileSystemEntity.typeSync(normalisedPath) !=
        FileSystemEntityType.file) {
      throw ArgumentError.value(
        filePath,
        'filePath',
        'log file does not exist',
      );
    }
    await Process.start(
      _explorerPath,
      <String>['/select,', normalisedPath],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
  }

  ProcessCommand _vcpkgCommand(
    VcpkgLayout layout,
    List<String> arguments, {
    bool jsonOutput = false,
  }) => ProcessCommand(
    executable: layout.executablePath,
    arguments: arguments,
    workingDirectory: layout.rootDirectory,
    environment: <String, String>{'VCPKG_ROOT': layout.rootDirectory},
    stdoutDecoder: jsonOutput
        ? const OutputDecoderPolicy.utf8()
        : const OutputDecoderPolicy.system(),
    stderrDecoder: const OutputDecoderPolicy.system(),
  );

  static String _validatePackageName(String value) {
    final String packageName = value.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9][a-z0-9+_.-]*$').hasMatch(packageName)) {
      throw ArgumentError.value(
        value,
        'packageName',
        'contains unsupported characters',
      );
    }
    return packageName;
  }

  static String _validateTriplet(String value) {
    final String triplet = value.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9][a-z0-9+_.-]*$').hasMatch(triplet)) {
      throw ArgumentError.value(
        value,
        'VCPKG_DEFAULT_TRIPLET',
        'contains unsupported characters',
      );
    }
    return triplet;
  }

  static bool _isInside(String candidate, String root) =>
      _windowsPath.equals(candidate, root) ||
      _windowsPath.isWithin(root, candidate);
}
