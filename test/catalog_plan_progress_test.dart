import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/application/package_catalog_service.dart';
import 'package:vcpkg_ui/application/progress_parser.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';
import 'package:vcpkg_ui/domain/progress_models.dart';
import 'package:vcpkg_ui/infrastructure/platform/vcpkg_platform_adapter.dart';
import 'package:vcpkg_ui/infrastructure/process/process_command.dart';
import 'package:vcpkg_ui/infrastructure/process/process_runner.dart';

void main() {
  test(
    'catalog combines JSON and CONTROL metadata with installed JSON',
    () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-catalog-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final Directory root = Directory(path.join(workspace.path, 'fake root'));
      final Directory ports = Directory(path.join(root.path, 'ports'));
      await ports.create(recursive: true);

      final Directory alpha = Directory(path.join(ports.path, 'alpha'));
      await alpha.create();
      await File(path.join(alpha.path, 'vcpkg.json')).writeAsString('''
{
  "name": "alpha",
  "version-semver": "1.2.3",
  "port-version": 2,
  "description": ["first line", "second line"]
}
''');

      final Directory legacy = Directory(path.join(ports.path, 'legacy'));
      await legacy.create();
      await File(path.join(legacy.path, 'CONTROL')).writeAsString('''
Source: legacy
Version: 4.5
Port-Version: 1
Description: legacy package
 continued description
Build-Depends: alpha
''');

      final Directory malformed = Directory(path.join(ports.path, 'broken'));
      await malformed.create();
      await File(path.join(malformed.path, 'vcpkg.json')).writeAsString('''
{
  "name": "not a valid package name!",
  "version": "9.9"
}
''');

      final File installedJson = File(
        path.join(workspace.path, 'installed.json'),
      );
      await installedJson.writeAsString('''
{
  "alpha:x64-windows": {
    "package_name": "alpha",
    "triplet": "x64-windows",
    "version": "1.2.3",
    "port_version": 2,
    "features": ["core", "tools"]
  }
}
''');

      final VcpkgLayout layout = VcpkgLayout(
        rootDirectory: root.path,
        rootMarkerPath: path.join(root.path, '.vcpkg-root'),
        portsDirectory: ports.path,
        executablePath: path.join(root.path, 'fake-vcpkg'),
        removeAllScriptPath: path.join(root.path, 'remove-all'),
        fullInstallScriptPath: path.join(root.path, 'fake-setup'),
      );
      final ProcessCommand listCommand = _fixtureCommand(
        workspace.path,
        stdoutFile: installedJson.path,
      );
      final PackageCatalogService catalog = PackageCatalogService(
        adapter: _CommandAdapter(listCommand: listCommand),
        runner: const ProcessRunner(),
        layout: layout,
      );
      final Map<String, DateTime> timestampsBefore = await _fileTimestamps(
        root,
      );

      final List<PackageViewState> packages = await catalog.load();

      expect(
        packages.map((PackageViewState item) => item.metadata.name),
        <String>['alpha', 'broken', 'legacy'],
      );
      final PackageViewState alphaState = packages.first;
      expect(alphaState.metadata.availableVersion, '1.2.3#2');
      expect(alphaState.metadata.sourceVersion, '1.2.3');
      expect(alphaState.metadata.versionScheme, VcpkgVersionScheme.semver);
      expect(alphaState.metadata.portVersion, 2);
      expect(alphaState.metadata.description, 'first line\nsecond line');
      expect(alphaState.isInstalled, isTrue);
      expect(alphaState.installed.single.version, '1.2.3#2');
      expect(alphaState.installed.single.triplet, 'x64-windows');
      expect(alphaState.installed.single.features, <String>['core', 'tools']);

      final PackageViewState brokenState = packages[1];
      expect(brokenState.metadata.name, 'broken');
      expect(brokenState.metadata.hasMetadataError, isTrue);
      expect(brokenState.metadata.metadataError, contains('package name'));

      final PackageViewState legacyState = packages.last;
      expect(legacyState.metadata.availableVersion, '4.5#1');
      expect(
        legacyState.metadata.description,
        'legacy package continued description',
      );
      expect(legacyState.isInstalled, isFalse);
      expect(await _fileTimestamps(root), timestampsBefore);
    },
  );

  group('WindowsVcpkgProgressParser', () {
    late FullInstallPlan plan;
    late WindowsVcpkgProgressParser parser;
    late ProgressAccumulator accumulator;

    setUp(() {
      plan = FullInstallPlan(
        slots: <TargetSlot>[
          TargetSlot(
            id: 'a',
            category: 'Base Components',
            variants: <PackageSpec>[PackageSpec.parse('alpha:x64-windows')],
          ),
          TargetSlot(
            id: 'b',
            category: 'Base Components',
            variants: <PackageSpec>[PackageSpec.parse('beta:x64-windows')],
          ),
        ],
      );
      parser = WindowsVcpkgProgressParser(plan);
      accumulator = ProgressAccumulator(plan);
    });

    test(
      'tracks current category, actual library, stage, and transitive work',
      () {
        _applyLine(parser, accumulator, 'CATEGORY: "Base Components"');
        _applyLine(parser, accumulator, 'Building alpha:x64-windows...');

        expect(accumulator.snapshot.currentCategory, 'Base Components');
        expect(accumulator.snapshot.currentPackage?.name, 'alpha');
        expect(accumulator.snapshot.currentStage, BuildStage.building);

        _applyLine(parser, accumulator, 'Building zlib:x64-windows...');
        expect(accumulator.snapshot.currentPackage?.name, 'zlib');
        expect(accumulator.snapshot.completedTargetSlots, 0);
        expect(accumulator.snapshot.totalTargetSlots, 2);
      },
    );

    test('progress is monotonic across completion, retry, and duplicates', () {
      _applyLine(parser, accumulator, 'CATEGORY: "Base Components"');
      _applyLine(
        parser,
        accumulator,
        'Elapsed time to handle alpha:x64-windows: 1 s',
      );
      expect(accumulator.snapshot.completedTargetSlots, 1);

      _applyLine(
        parser,
        accumulator,
        'Retry installing "Base Components" (Try 2 of 3)',
      );
      expect(accumulator.snapshot.currentStage, BuildStage.retrying);
      expect(accumulator.snapshot.retryAttempt, 2);
      expect(accumulator.snapshot.completedTargetSlots, 1);

      _applyLine(
        parser,
        accumulator,
        'Elapsed time to handle alpha:x64-windows: 2 s',
      );
      expect(accumulator.snapshot.completedTargetSlots, 1);

      _applyLine(
        parser,
        accumulator,
        'Successfully installed category: "Base Components"',
      );
      expect(accumulator.snapshot.completedTargetSlots, 2);
      expect(accumulator.snapshot.fraction, 1);
    });

    test(
      'category completion is the fallback when package lines are absent',
      () {
        _applyLine(
          parser,
          accumulator,
          'Installing category: "Base Components"',
        );
        expect(accumulator.snapshot.completedTargetSlots, 0);

        _applyLine(
          parser,
          accumulator,
          'Successfully installed category: "Base Components"',
        );
        expect(accumulator.snapshot.completedTargetSlotIds, <String>{'a', 'b'});
      },
    );
  });
}

void _applyLine(
  ProgressParser parser,
  ProgressAccumulator accumulator,
  String line,
) {
  for (final ProgressEvent event in parser.parseLine(line)) {
    accumulator.apply(event);
  }
}

Future<Map<String, DateTime>> _fileTimestamps(Directory root) async {
  final Map<String, DateTime> result = <String, DateTime>{};
  await for (final FileSystemEntity entity in root.list(recursive: true)) {
    if (entity is File) {
      result[path.relative(entity.path, from: root.path)] =
          (await entity.stat()).modified;
    }
  }
  return result;
}

ProcessCommand _fixtureCommand(
  String workingDirectory, {
  String? stdoutFile,
  String? stderrFile,
  int exitCode = 0,
}) {
  final String systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  final String powershell = path.join(
    systemRoot,
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );
  return ProcessCommand(
    executable: powershell,
    arguments: <String>[
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      path.absolute('test/fixtures/process_fixture.ps1'),
      if (stdoutFile != null) ...<String>['-StdoutFile', stdoutFile],
      if (stderrFile != null) ...<String>['-StderrFile', stderrFile],
      '-ExitCode',
      '$exitCode',
    ],
    workingDirectory: workingDirectory,
    stdoutDecoder: const OutputDecoderPolicy.utf8(),
    stderrDecoder: const OutputDecoderPolicy.utf8(),
  );
}

final class _CommandAdapter implements VcpkgPlatformAdapter {
  const _CommandAdapter({required this.listCommand});

  final ProcessCommand listCommand;

  @override
  String get platformId => 'test';

  @override
  ProcessCommand listInstalledCommand(VcpkgLayout layout) => listCommand;

  @override
  VcpkgLayout createLayout(String rawRoot) => throw UnsupportedError('unused');

  @override
  String defaultTriplet(Map<String, String> environment) => 'x64-test';

  @override
  ProcessCommand fullInstallCommand(VcpkgLayout layout) =>
      throw UnsupportedError('unused');

  @override
  ProcessCommand installCommand(
    VcpkgLayout layout,
    PackageSpec specification,
  ) => throw UnsupportedError('unused');

  @override
  String logDirectoryPath(
    Map<String, String> environment, {
    VcpkgLayout? layout,
  }) => throw UnsupportedError('unused');

  @override
  Future<void> openLogFile(String filePath) async {}

  @override
  ProcessCommand packageInfoCommand(VcpkgLayout layout, String packageName) =>
      throw UnsupportedError('unused');

  @override
  ProcessCommand removeCommand(
    VcpkgLayout layout,
    PackageSpec specification, {
    required bool recurse,
  }) => throw UnsupportedError('unused');

  @override
  ProcessCommand removeAllCommand(VcpkgLayout layout) =>
      throw UnsupportedError('unused');

  @override
  ProcessCommand upgradePreviewCommand(VcpkgLayout layout) =>
      throw UnsupportedError('unused');

  @override
  ProcessCommand upgradeAllCommand(VcpkgLayout layout) =>
      throw UnsupportedError('unused');

  @override
  ProcessCommand removePreviewCommand(
    VcpkgLayout layout,
    PackageSpec specification,
  ) => throw UnsupportedError('unused');

  @override
  List<RequiredArtifact> requiredArtifacts(VcpkgLayout layout) =>
      const <RequiredArtifact>[];

  @override
  List<ValidationIssue> validateLayout(VcpkgLayout layout) =>
      const <ValidationIssue>[];
}
