import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/application/full_install_plan_reader.dart';
import 'package:vcpkg_ui/application/progress_parser.dart';
import 'package:vcpkg_ui/app/default_vcpkg_ui_gateway.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_gateway.dart';
import 'package:vcpkg_ui/domain/output_models.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/domain/progress_models.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';
import 'package:vcpkg_ui/infrastructure/platform/vcpkg_platform_adapter.dart';
import 'package:vcpkg_ui/infrastructure/process/process_command.dart';

void main() {
  test(
    'DefaultVcpkgUiGateway supports the complete common flow with a fake Linux adapter',
    () async {
      final _GatewayFixture fixture = await _GatewayFixture.create();
      addTearDown(fixture.dispose);

      final StartupResult startup = await fixture.gateway.initialize(
        fixture.events,
      );

      expect(startup, isA<StartupSuccess>());
      final StartupSuccess success = startup as StartupSuccess;
      expect(success.rootPath, fixture.root.path);
      expect(fixture.events.validatedRoot, fixture.root.path);
      expect(success.packages.map((PackageUiModel item) => item.name), <String>[
        'alpha',
        'beta',
        'broken',
      ]);
      final PackageUiModel broken = success.packages.singleWhere(
        (PackageUiModel item) => item.name == 'broken',
      );
      expect(broken.package.metadata.hasMetadataError, isTrue);
      expect(
        fixture.events.output,
        contains(
          isA<OutputLine>().having(
            (OutputLine line) => line.text,
            'metadata warning',
            allOf(contains('broken'), contains('package name')),
          ),
        ),
      );

      final VendorVersionScanResult vendorVersions = await fixture.gateway
          .checkVendorVersions(fixture.events);
      expect(vendorVersions.packages.keys, <String>['alpha']);
      expect(
        vendorVersions.packages['alpha']!.status,
        VendorVersionStatus.unsupported,
      );
      expect(vendorVersions.logPath, isNotNull);
      expect(await File(vendorVersions.logPath!).exists(), isTrue);
      final String vendorLog = await File(
        vendorVersions.logPath!,
      ).readAsString();
      expect(vendorLog, contains('[UNSUPPORTED] alpha'));
      expect(vendorLog, contains('reason=portfile.cmake does not exist'));
      expect(vendorLog, contains('Vendor version check completed:'));
      expect(fixture.events.vendorVersionProgress.last.completed, 1);

      final PackageUiModel beta = success.packages.singleWhere(
        (PackageUiModel item) => item.name == 'beta',
      );
      expect(beta.installSpecification?.vcpkgArgument, 'beta:x64-linux');
      final OperationResult install = await fixture.gateway.install(
        beta,
        fixture.events,
      );
      expect(install.succeeded, isTrue);
      expect(fixture.adapter.installed.single, 'beta:x64-linux');
      expect(
        await fixture.gateway.refreshCatalog(fixture.events),
        hasLength(3),
      );

      final PackageUiModel alpha = success.packages.singleWhere(
        (PackageUiModel item) => item.name == 'alpha',
      );
      final RemovePreviewResult preview = await fixture.gateway.previewRemove(
        alpha,
        fixture.events,
      );
      expect(preview.requiresRecursiveRemoval, isFalse);
      expect(preview.summary, contains('alpha:x64-linux'));

      final OperationResult remove = await fixture.gateway.remove(
        alpha,
        recurse: false,
        events: fixture.events,
      );
      expect(remove.succeeded, isTrue);
      expect(fixture.adapter.removed.single, 'alpha:x64-linux');

      final OperationResult removeAll = await fixture.gateway.removeAll(
        fixture.events,
      );
      expect(removeAll.succeeded, isTrue);

      final UpdatePreviewResult updatePreview = await fixture.gateway
          .previewUpdates(fixture.events);
      expect(updatePreview.hasUpdates, isTrue);
      expect(updatePreview.plannedPackages, <String>[
        'alpha:x64-linux@2.0',
        'beta:x64-linux@3.0',
      ]);
      final OperationResult updateAll = await fixture.gateway.updateAll(
        fixture.events,
      );
      expect(updateAll.succeeded, isTrue);

      final OperationResult full = await fixture.gateway.runFullInstallation(
        fixture.events,
      );
      expect(full.succeeded, isTrue);
      expect(fixture.events.progress, isNotEmpty);
      expect(fixture.events.progress.last.totalTargetSlots, 1);
      expect(fixture.events.progress.last.completedTargetSlots, 1);
      expect(fixture.events.progress.last.currentStage, BuildStage.completed);
      expect(
        fixture.events.progress
            .map((ProgressSnapshot item) => item.currentPackage?.name)
            .whereType<String>(),
        contains('alpha'),
      );

      expect(fixture.events.runningLogPaths, hasLength(7));
      for (final String logPath in fixture.events.runningLogPaths) {
        expect(path.isWithin(fixture.root.path, logPath), isFalse);
        expect(await File(logPath).exists(), isTrue);
      }
      final List<File> logFiles = await Directory(fixture.logsPath)
          .list()
          .where((FileSystemEntity item) => item is File)
          .cast<File>()
          .toList();
      expect(logFiles, hasLength(8));
      final String combinedLogs = (await Future.wait(
        logFiles.map((File file) => file.readAsString()),
      )).join('\n');
      expect(combinedLogs, contains('fake install completed'));
      expect(combinedLogs, contains('fake remove completed'));
      expect(combinedLogs, contains('fake remove all completed'));
      expect(combinedLogs, contains('fake update all completed'));
      expect(combinedLogs, contains('BUILD alpha:x64-linux'));

      expect(
        fixture.events.output
            .where((OutputLine line) => line.source == OutputSource.stdout)
            .map((OutputLine line) => line.text),
        containsAll(<String>[
          'fake install completed',
          'fake remove completed',
          'fake remove all completed',
          'fake update all completed',
          'BUILD alpha:x64-linux',
        ]),
      );
      expect(
        fixture.adapter.calls,
        containsAll(<String>[
          'list',
          'install',
          'remove-preview',
          'remove',
          'remove-all',
          'update-preview',
          'update-all',
          'full-install',
        ]),
      );
    },
  );
}

final class _GatewayFixture {
  _GatewayFixture._({
    required this.workspace,
    required this.root,
    required this.logsPath,
    required this.adapter,
    required this.gateway,
    required this.events,
  });

  final Directory workspace;
  final Directory root;
  final String logsPath;
  final _FakeLinuxAdapter adapter;
  final DefaultVcpkgUiGateway gateway;
  final _RecordingEvents events;

  static Future<_GatewayFixture> create() async {
    final Directory workspace = await Directory.systemTemp.createTemp(
      'vcpkg-ui-linux-contract-',
    );
    final Directory root = Directory(path.join(workspace.path, 'fake vcpkg'));
    final Directory ports = Directory(path.join(root.path, 'ports'));
    await ports.create(recursive: true);
    await File(path.join(root.path, '.vcpkg-root')).writeAsString('');
    await File(path.join(root.path, 'vcpkg')).writeAsString('fake executable');
    await File(
      path.join(root.path, 'remove-all.sh'),
    ).writeAsString('# fake script: it is never executed by this test');
    await File(
      path.join(root.path, 'first-setup.sh'),
    ).writeAsString('# fake script: it is never executed by this test');

    await _writeManifest(ports, 'alpha', '{"name":"alpha","version":"1.0"}');
    await _writeManifest(
      ports,
      'beta',
      '{"name":"beta","version-string":"2.0"}',
    );
    await _writeManifest(
      ports,
      'broken',
      '{"name":"invalid name!","version":"3.0"}',
    );

    final File installed = await _writeOutput(workspace, 'installed.json', '''
{
  "alpha:x64-linux": {
    "package_name": "alpha",
    "triplet": "x64-linux",
    "version": "1.0",
    "port_version": 0,
    "features": ["core"]
  }
}
''');
    final File installOutput = await _writeOutput(
      workspace,
      'install.txt',
      'fake install completed',
    );
    final File previewOutput = await _writeOutput(workspace, 'preview.txt', '''
The following packages will be removed:
    alpha:x64-linux
''');
    final File removeOutput = await _writeOutput(
      workspace,
      'remove.txt',
      'fake remove completed',
    );
    final File removeAllOutput = await _writeOutput(
      workspace,
      'remove-all.txt',
      'fake remove all completed',
    );
    final File updatePreviewOutput = await _writeOutput(
      workspace,
      'update-preview.txt',
      '''
The following packages will be rebuilt:
  * alpha:x64-linux@2.0
  * beta:x64-linux@3.0
Additional packages (*) will be modified to complete this operation.
''',
    );
    final File updateAllOutput = await _writeOutput(
      workspace,
      'update-all.txt',
      'fake update all completed',
    );
    final File fullOutput = await _writeOutput(workspace, 'full.txt', '''
CATEGORY Core
BUILD alpha:x64-linux
DONE alpha:x64-linux
CATEGORY-DONE Core
''');
    final String logsPath = path.join(workspace.path, 'application logs');
    final _FakeLinuxAdapter adapter = _FakeLinuxAdapter(
      workspace: workspace.path,
      logsPath: logsPath,
      listCommand: _fixtureCommand(root.path, stdoutFile: installed.path),
      installCommandFixture: _fixtureCommand(
        root.path,
        stdoutFile: installOutput.path,
      ),
      previewCommandFixture: _fixtureCommand(
        root.path,
        stdoutFile: previewOutput.path,
        exitCode: 0,
      ),
      removeCommandFixture: _fixtureCommand(
        root.path,
        stdoutFile: removeOutput.path,
      ),
      removeAllCommandFixture: _fixtureCommand(
        root.path,
        stdoutFile: removeAllOutput.path,
      ),
      updatePreviewCommandFixture: _fixtureCommand(
        root.path,
        stdoutFile: updatePreviewOutput.path,
        exitCode: 1,
      ),
      updateAllCommandFixture: _fixtureCommand(
        root.path,
        stdoutFile: updateAllOutput.path,
      ),
      fullCommandFixture: _fixtureCommand(
        root.path,
        stdoutFile: fullOutput.path,
      ),
    );
    final FullInstallPlan plan = FullInstallPlan(
      slots: <TargetSlot>[
        TargetSlot(
          id: 'core:alpha',
          category: 'Core',
          variants: <PackageSpec>[PackageSpec.parse('alpha:x64-linux')],
        ),
      ],
    );
    final DefaultVcpkgUiGateway gateway = DefaultVcpkgUiGateway(
      adapter,
      _FakeLinuxPlanReader(plan),
      _FakeLinuxProgressParser.new,
      environment: <String, String>{'VCPKG_ROOT': root.path},
    );
    return _GatewayFixture._(
      workspace: workspace,
      root: root,
      logsPath: logsPath,
      adapter: adapter,
      gateway: gateway,
      events: _RecordingEvents(),
    );
  }

  static Future<void> _writeManifest(
    Directory ports,
    String directoryName,
    String contents,
  ) async {
    final Directory directory = Directory(path.join(ports.path, directoryName));
    await directory.create();
    await File(path.join(directory.path, 'vcpkg.json')).writeAsString(contents);
  }

  static Future<File> _writeOutput(
    Directory workspace,
    String name,
    String contents,
  ) async => File(path.join(workspace.path, name))..writeAsStringSync(contents);

  Future<void> dispose() => workspace.delete(recursive: true);
}

final class _FakeLinuxAdapter implements VcpkgPlatformAdapter {
  _FakeLinuxAdapter({
    required this.workspace,
    required this.logsPath,
    required this.listCommand,
    required this.installCommandFixture,
    required this.previewCommandFixture,
    required this.removeCommandFixture,
    required this.removeAllCommandFixture,
    required this.updatePreviewCommandFixture,
    required this.updateAllCommandFixture,
    required this.fullCommandFixture,
  });

  final String workspace;
  final String logsPath;
  final ProcessCommand listCommand;
  final ProcessCommand installCommandFixture;
  final ProcessCommand previewCommandFixture;
  final ProcessCommand removeCommandFixture;
  final ProcessCommand removeAllCommandFixture;
  final ProcessCommand updatePreviewCommandFixture;
  final ProcessCommand updateAllCommandFixture;
  final ProcessCommand fullCommandFixture;
  final List<String> calls = <String>[];
  final List<String> installed = <String>[];
  final List<String> removed = <String>[];

  @override
  String get platformId => 'fake-linux';

  @override
  VcpkgLayout createLayout(String rawRoot) {
    final String root = path.normalize(path.absolute(rawRoot.trim()));
    return VcpkgLayout(
      rootDirectory: root,
      rootMarkerPath: path.join(root, '.vcpkg-root'),
      portsDirectory: path.join(root, 'ports'),
      executablePath: path.join(root, 'vcpkg'),
      removeAllScriptPath: path.join(root, 'remove-all.sh'),
      fullInstallScriptPath: path.join(root, 'first-setup.sh'),
    );
  }

  @override
  List<RequiredArtifact> requiredArtifacts(VcpkgLayout layout) =>
      <RequiredArtifact>[
        RequiredArtifact(
          code: 'root_directory_missing',
          path: layout.rootDirectory,
          kind: ArtifactKind.directory,
          description: 'fake Linux root',
        ),
        RequiredArtifact(
          code: 'root_marker_missing',
          path: layout.rootMarkerPath,
          kind: ArtifactKind.file,
          description: 'root marker',
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
          description: 'fake Linux executable',
        ),
        RequiredArtifact(
          code: 'remove_all_script_missing',
          path: layout.removeAllScriptPath,
          kind: ArtifactKind.file,
          description: 'fake Linux remove-all script',
        ),
        RequiredArtifact(
          code: 'full_install_script_missing',
          path: layout.fullInstallScriptPath,
          kind: ArtifactKind.file,
          description: 'fake Linux setup script',
        ),
      ];

  @override
  List<ValidationIssue> validateLayout(VcpkgLayout layout) {
    final List<ValidationIssue> issues = <ValidationIssue>[];
    for (final RequiredArtifact artifact in requiredArtifacts(layout)) {
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        artifact.path,
      );
      final bool valid = switch (artifact.kind) {
        ArtifactKind.file => type == FileSystemEntityType.file,
        ArtifactKind.directory => type == FileSystemEntityType.directory,
      };
      if (!valid) {
        issues.add(
          ValidationIssue(
            code: artifact.code,
            message: '${artifact.description} is missing',
            path: artifact.path,
          ),
        );
      }
    }
    return issues;
  }

  @override
  String defaultTriplet(Map<String, String> environment) => 'x64-linux';

  @override
  ProcessCommand listInstalledCommand(VcpkgLayout layout) {
    calls.add('list');
    return listCommand;
  }

  @override
  ProcessCommand packageInfoCommand(VcpkgLayout layout, String packageName) =>
      throw UnsupportedError('not used by the current catalog implementation');

  @override
  ProcessCommand installCommand(VcpkgLayout layout, PackageSpec specification) {
    calls.add('install');
    installed.add(specification.vcpkgArgument);
    return installCommandFixture;
  }

  @override
  ProcessCommand removePreviewCommand(
    VcpkgLayout layout,
    PackageSpec specification,
  ) {
    calls.add('remove-preview');
    return previewCommandFixture;
  }

  @override
  ProcessCommand removeCommand(
    VcpkgLayout layout,
    PackageSpec specification, {
    required bool recurse,
  }) {
    calls.add('remove');
    removed.add(specification.vcpkgArgument);
    return removeCommandFixture;
  }

  @override
  ProcessCommand removeAllCommand(VcpkgLayout layout) {
    calls.add('remove-all');
    return removeAllCommandFixture;
  }

  @override
  ProcessCommand upgradePreviewCommand(VcpkgLayout layout) {
    calls.add('update-preview');
    return updatePreviewCommandFixture;
  }

  @override
  ProcessCommand upgradeAllCommand(VcpkgLayout layout) {
    calls.add('update-all');
    return updateAllCommandFixture;
  }

  @override
  ProcessCommand fullInstallCommand(VcpkgLayout layout) {
    calls.add('full-install');
    return fullCommandFixture;
  }

  @override
  String logDirectoryPath(
    Map<String, String> environment, {
    VcpkgLayout? layout,
  }) => logsPath;

  @override
  Future<void> openLogFile(String filePath) async {}
}

final class _FakeLinuxPlanReader implements FullInstallPlanReader {
  const _FakeLinuxPlanReader(this.plan);

  final FullInstallPlan plan;

  @override
  Future<FullInstallPlan> read(String scriptPath) async {
    if (!await File(scriptPath).exists()) {
      throw StateError('fake Linux setup script is missing');
    }
    return plan;
  }
}

final class _FakeLinuxProgressParser implements ProgressParser {
  const _FakeLinuxProgressParser(this.plan);

  final FullInstallPlan plan;

  @override
  List<ProgressEvent> parseLine(String line) {
    if (line.startsWith('CATEGORY ')) {
      return <ProgressEvent>[
        ProgressCategoryChanged(line.substring('CATEGORY '.length)),
      ];
    }
    if (line.startsWith('BUILD ')) {
      return <ProgressEvent>[
        ProgressPackageChanged(
          specification: PackageSpec.parse(line.substring('BUILD '.length)),
          stage: BuildStage.building,
        ),
      ];
    }
    if (line.startsWith('DONE ')) {
      final PackageSpec specification = PackageSpec.parse(
        line.substring('DONE '.length),
      );
      final TargetSlot slot = plan.slots.singleWhere(
        (TargetSlot item) => item.matches(specification),
      );
      return <ProgressEvent>[ProgressTargetCompleted(slot.id)];
    }
    if (line.startsWith('CATEGORY-DONE ')) {
      return <ProgressEvent>[
        ProgressCategoryCompleted(line.substring('CATEGORY-DONE '.length)),
      ];
    }
    return const <ProgressEvent>[];
  }
}

final class _RecordingEvents implements VcpkgUiEventSink {
  String? validatedRoot;
  final List<String> runningLogPaths = <String>[];
  final List<OutputLine> output = <OutputLine>[];
  final List<ProgressSnapshot> progress = <ProgressSnapshot>[];
  final List<VendorVersionCheckProgress> vendorVersionProgress =
      <VendorVersionCheckProgress>[];

  @override
  void onRootValidated(String rootPath) => validatedRoot = rootPath;

  @override
  void onOperationRunning({String? logPath}) {
    if (logPath != null) {
      runningLogPaths.add(logPath);
    }
  }

  @override
  void onOutput(OutputLine line) => output.add(line);

  @override
  void onProgress(ProgressSnapshot snapshot) => progress.add(snapshot);

  @override
  void onVendorVersionProgress(VendorVersionCheckProgress progress) =>
      vendorVersionProgress.add(progress);
}

ProcessCommand _fixtureCommand(
  String workingDirectory, {
  required String stdoutFile,
  int exitCode = 0,
}) {
  final String systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return ProcessCommand(
    executable: path.join(
      systemRoot,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    ),
    arguments: <String>[
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      path.absolute('test/fixtures/process_fixture.ps1'),
      '-StdoutFile',
      stdoutFile,
      '-ExitCode',
      '$exitCode',
    ],
    workingDirectory: workingDirectory,
    stdoutDecoder: const OutputDecoderPolicy.utf8(),
    stderrDecoder: const OutputDecoderPolicy.utf8(),
  );
}
