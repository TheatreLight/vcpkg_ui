import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/application/full_install_plan_reader.dart';
import 'package:vcpkg_ui/application/progress_parser.dart';
import 'package:vcpkg_ui/application/vcpkg_operation_service.dart';
import 'package:vcpkg_ui/domain/operation_models.dart';
import 'package:vcpkg_ui/domain/output_models.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/infrastructure/logging/log_store.dart';
import 'package:vcpkg_ui/infrastructure/platform/vcpkg_platform_adapter.dart';
import 'package:vcpkg_ui/infrastructure/process/process_command.dart';
import 'package:vcpkg_ui/infrastructure/process/process_runner.dart';

void main() {
  test(
    'ProcessRunner drains stdout/stderr final lines and closes the log before returning',
    () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-process-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final OperationLog log = await LogStore(
        path.join(workspace.path, 'application logs'),
      ).create(OperationKind.install);
      final List<OutputLine> lines = <OutputLine>[];

      final ProcessRunResult result = await const ProcessRunner().run(
        _fixtureCommand(workspace.path, exitCode: 7),
        log: log,
        captureOutput: true,
        onOutput: lines.add,
      );

      expect(result.started, isTrue);
      expect(result.exitCode, 7);
      expect(result.errorMessage, isNull);
      expect(result.capturedStdout, 'stdout first\nstdout final');
      expect(result.capturedStderr, 'stderr first\nstderr final');
      expect(
        lines
            .where((OutputLine line) => line.source == OutputSource.stdout)
            .map((OutputLine line) => line.text),
        containsAllInOrder(<String>['stdout first', 'stdout final']),
      );
      expect(
        lines
            .where((OutputLine line) => line.source == OutputSource.stderr)
            .map((OutputLine line) => line.text),
        containsAllInOrder(<String>['stderr first', 'stderr final']),
      );

      // Reading complete content immediately after run verifies that the
      // runner awaited IOSink.flush/close after both pipe EOFs.
      final String logText = await File(result.logPath!).readAsString();
      expect(logText, contains('[stdout] stdout final'));
      expect(logText, contains('[stderr] stderr final'));
      await File(result.logPath!).rename('${result.logPath}.closed');
    },
  );

  group('remove preview safety', () {
    for (final int acceptedExitCode in <int>[0, 1]) {
      test(
        'accepts structured dry-run plan with exit code $acceptedExitCode',
        () async {
          final _OperationFixture fixture = await _OperationFixture.create(
            stdout: '''
The following packages will be removed:
    alpha:x64-windows
  * beta:x64-windows
''',
            exitCode: acceptedExitCode,
          );
          addTearDown(fixture.dispose);
          final VcpkgOperationService service = fixture.createService();
          final PackageSpec requested = PackageSpec.parse('alpha:x64-windows');

          final RemovePreview preview = await service.previewRemove(requested);

          expect(preview.processResult.exitCode, acceptedExitCode);
          expect(
            preview.affectedPackages.map((PackageSpec item) => item.name),
            <String>['alpha', 'beta'],
          );
          expect(preview.requiresRecurse, isTrue);
          expect(service.coordinator.state.phase, OperationPhase.succeeded);
          expect(
            () => service.remove(preview, confirmedRecursiveRemoval: false),
            throwsA(isA<StateError>()),
          );
        },
      );
    }

    test(
      'rejects structured-looking output when exit code is 2 or greater',
      () async {
        final _OperationFixture fixture = await _OperationFixture.create(
          stdout: '''
The following packages will be removed:
    alpha:x64-windows
''',
          exitCode: 2,
        );
        addTearDown(fixture.dispose);
        final VcpkgOperationService service = fixture.createService();

        await expectLater(
          service.previewRemove(PackageSpec.parse('alpha:x64-windows')),
          throwsA(isA<StateError>()),
        );
        expect(service.coordinator.state.phase, OperationPhase.failed);
        expect(service.coordinator.state.exitCode, 2);
      },
    );

    test('rejects partial output without the requested package', () async {
      final _OperationFixture fixture = await _OperationFixture.create(
        stdout: '''
The following packages will be removed:
    beta:x64-windows
''',
        exitCode: 1,
      );
      addTearDown(fixture.dispose);
      final VcpkgOperationService service = fixture.createService();

      await expectLater(
        service.previewRemove(PackageSpec.parse('alpha:x64-windows')),
        throwsA(isA<StateError>()),
      );
      expect(service.coordinator.state.phase, OperationPhase.failed);
    });
  });

  test(
    'post-success catalog refresh failure keeps process and state successful',
    () async {
      final _OperationFixture fixture = await _OperationFixture.create(
        stdout: 'install completed',
        exitCode: 0,
      );
      addTearDown(fixture.dispose);
      final List<OutputLine> output = <OutputLine>[];
      final VcpkgOperationService service = fixture.createService(
        refreshCatalog: () async => throw StateError('refresh exploded'),
        onOutput: output.add,
      );

      final ProcessRunResult result = await service.install(
        PackageSpec.parse('alpha:x64-windows'),
      );

      expect(result.succeeded, isTrue);
      expect(service.coordinator.state.phase, OperationPhase.succeeded);
      expect(service.coordinator.state.exitCode, 0);
      expect(
        output.where((OutputLine line) => line.source == OutputSource.system),
        contains(
          isA<OutputLine>().having(
            (OutputLine line) => line.text.toLowerCase(),
            'warning text',
            allOf(contains('refresh'), contains('refresh exploded')),
          ),
        ),
      );
    },
  );

  test('OperationCoordinator enforces a single active mutation', () {
    final OperationCoordinator coordinator = OperationCoordinator();
    coordinator.begin(OperationKind.install);

    expect(coordinator.isActive, isTrue);
    expect(
      () => coordinator.begin(OperationKind.remove),
      throwsA(isA<OperationInProgressException>()),
    );
    coordinator.failed(OperationKind.install, message: 'simulated');
    expect(coordinator.state.isTerminal, isTrue);
    expect(() => coordinator.begin(OperationKind.remove), returnsNormally);
  });
}

final class _OperationFixture {
  _OperationFixture._({
    required this.workspace,
    required this.layout,
    required this.command,
  });

  final Directory workspace;
  final VcpkgLayout layout;
  final ProcessCommand command;

  static Future<_OperationFixture> create({
    required String stdout,
    required int exitCode,
  }) async {
    final Directory workspace = await Directory.systemTemp.createTemp(
      'vcpkg-ui-remove-',
    );
    final Directory root = Directory(path.join(workspace.path, 'fake root'));
    await root.create(recursive: true);
    final File stdoutFile = File(path.join(workspace.path, 'stdout.txt'));
    await stdoutFile.writeAsString(stdout);
    final VcpkgLayout layout = VcpkgLayout(
      rootDirectory: root.path,
      rootMarkerPath: path.join(root.path, '.vcpkg-root'),
      portsDirectory: path.join(root.path, 'ports'),
      executablePath: path.join(root.path, 'vcpkg'),
      removeAllScriptPath: path.join(root.path, 'remove-all'),
      fullInstallScriptPath: path.join(root.path, 'first-setup'),
    );
    return _OperationFixture._(
      workspace: workspace,
      layout: layout,
      command: _fixtureCommand(
        root.path,
        stdoutFile: stdoutFile.path,
        exitCode: exitCode,
      ),
    );
  }

  VcpkgOperationService createService({
    CatalogRefreshCallback? refreshCatalog,
    OutputLineCallback? onOutput,
  }) => VcpkgOperationService(
    adapter: _OperationAdapter(command),
    layout: layout,
    runner: const ProcessRunner(),
    logStore: LogStore(path.join(workspace.path, 'logs outside root')),
    planReader: const WindowsBatchFullInstallPlanReader(),
    progressParserFactory: WindowsVcpkgProgressParser.new,
    coordinator: OperationCoordinator(),
    refreshCatalog: refreshCatalog,
    onOutput: onOutput,
  );

  Future<void> dispose() => workspace.delete(recursive: true);
}

ProcessCommand _fixtureCommand(
  String workingDirectory, {
  String? stdoutFile,
  String? stderrFile,
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

final class _OperationAdapter implements VcpkgPlatformAdapter {
  const _OperationAdapter(this.previewCommand);

  final ProcessCommand previewCommand;

  @override
  String get platformId => 'operation-test';

  @override
  ProcessCommand removePreviewCommand(
    VcpkgLayout layout,
    PackageSpec specification,
  ) => previewCommand;

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
  ) => previewCommand;

  @override
  ProcessCommand listInstalledCommand(VcpkgLayout layout) =>
      throw UnsupportedError('unused');

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
  ProcessCommand removeAllCommand(VcpkgLayout layout) => previewCommand;

  @override
  ProcessCommand upgradePreviewCommand(VcpkgLayout layout) => previewCommand;

  @override
  ProcessCommand upgradeAllCommand(VcpkgLayout layout) => previewCommand;

  @override
  List<RequiredArtifact> requiredArtifacts(VcpkgLayout layout) =>
      const <RequiredArtifact>[];

  @override
  List<ValidationIssue> validateLayout(VcpkgLayout layout) =>
      const <ValidationIssue>[];
}
