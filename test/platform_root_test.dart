import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/application/vcpkg_ui_config.dart';
import 'package:vcpkg_ui/application/vcpkg_root_validator.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/infrastructure/platform/vcpkg_platform_adapter.dart';
import 'package:vcpkg_ui/infrastructure/platform/windows_vcpkg_platform_adapter.dart';
import 'package:vcpkg_ui/infrastructure/process/process_command.dart';
import 'package:vcpkg_ui/infrastructure/process/process_runner.dart';

void main() {
  group('VcpkgRootValidator with Windows adapter', () {
    test('reports a missing environment variable', () {
      final VcpkgRootValidationResult result = VcpkgRootValidator(
        WindowsVcpkgPlatformAdapter(configuration: _testConfiguration),
      ).validate(null);

      expect(result, isA<InvalidVcpkgRoot>());
      final InvalidVcpkgRoot invalid = result as InvalidVcpkgRoot;
      expect(invalid.issues.single.code, 'vcpkg_root_missing');
    });

    test(
      'accepts a complete disposable root whose path contains spaces',
      () async {
        final Directory workspace = await Directory.systemTemp.createTemp(
          'vcpkg ui root test ',
        );
        addTearDown(() => workspace.delete(recursive: true));
        final Directory root = Directory(
          path.join(workspace.path, 'root with spaces'),
        );
        await Directory(path.join(root.path, 'ports')).create(recursive: true);
        await File(path.join(root.path, '.vcpkg-root')).writeAsString('');
        await File(path.join(root.path, 'vcpkg.exe')).writeAsString('fake');
        await File(
          path.join(root.path, 'remove-all.cmd'),
        ).writeAsString('@echo off');
        await File(
          path.join(root.path, 'first-setup-categorical.cmd'),
        ).writeAsString('@echo off');

        final WindowsVcpkgPlatformAdapter adapter = WindowsVcpkgPlatformAdapter(
          configuration: _testConfiguration,
        );
        final VcpkgRootValidationResult result = VcpkgRootValidator(
          adapter,
        ).validate(root.path);

        expect(result, isA<ValidVcpkgRoot>());
        final VcpkgLayout layout = (result as ValidVcpkgRoot).layout;
        expect(layout.rootDirectory, path.normalize(root.absolute.path));
        expect(layout.executablePath, path.join(root.path, 'vcpkg.exe'));
      },
    );

    test('identifies a missing required artifact precisely', () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'vcpkg-ui-invalid-',
      );
      addTearDown(() => root.delete(recursive: true));

      final VcpkgRootValidationResult result = VcpkgRootValidator(
        WindowsVcpkgPlatformAdapter(configuration: _testConfiguration),
      ).validate(root.path);

      expect(result, isA<InvalidVcpkgRoot>());
      final List<String> codes = (result as InvalidVcpkgRoot).issues
          .map((ValidationIssue issue) => issue.code)
          .toList();
      expect(codes, contains('root_marker_missing'));
      expect(codes, contains('ports_directory_missing'));
      expect(codes, contains('vcpkg_executable_missing'));
      expect(codes, contains('remove_all_script_missing'));
      expect(codes, contains('full_install_script_missing'));
    });
  });

  group('WindowsVcpkgPlatformAdapter', () {
    late WindowsVcpkgPlatformAdapter adapter;
    late VcpkgLayout layout;

    setUp(() {
      adapter = WindowsVcpkgPlatformAdapter(
        configuration: _testConfiguration,
        environment: <String, String>{
          'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
          'PROCESSOR_ARCHITECTURE': 'AMD64',
          'LOCALAPPDATA': r'C:\Users\tester\AppData\Local',
        },
      );
      layout = adapter.createLayout(r'C:\work area\vcpkg fork');
    });

    test('keeps paths with spaces and builds typed commands', () {
      expect(layout.executablePath, r'C:\work area\vcpkg fork\vcpkg.exe');
      expect(adapter.listInstalledCommand(layout).arguments, <String>[
        'list',
        '--x-json',
      ]);

      final PackageSpec package = PackageSpec.parse(
        'openssl[core,tools]:x64-windows',
      );
      final ProcessCommand install = adapter.installCommand(layout, package);
      expect(install.executable, layout.executablePath);
      expect(install.arguments, <String>[
        'install',
        'openssl[core,tools]:x64-windows',
        '--disable-metrics',
      ]);
      expect(install.workingDirectory, layout.rootDirectory);
      expect(install.environment['VCPKG_ROOT'], layout.rootDirectory);

      expect(adapter.removePreviewCommand(layout, package).arguments, <String>[
        'remove',
        'openssl[core,tools]:x64-windows',
        '--dry-run',
      ]);

      final ProcessCommand full = adapter.fullInstallCommand(layout);
      expect(full.executable.toLowerCase(), endsWith(r'\system32\cmd.exe'));
      expect(full.arguments, <String>[
        '/d',
        '/s',
        '/c',
        'call',
        layout.fullInstallScriptPath,
      ]);
      expect(full.environment['VCPKG_ROOT'], layout.rootDirectory);

      final ProcessCommand removeAll = adapter.removeAllCommand(layout);
      expect(removeAll.arguments, <String>[
        '/d',
        '/s',
        '/c',
        'call',
        layout.removeAllScriptPath,
      ]);
      expect(adapter.upgradePreviewCommand(layout).arguments, <String>[
        'upgrade',
      ]);
      expect(adapter.upgradeAllCommand(layout).arguments, <String>[
        'upgrade',
        '--no-dry-run',
      ]);
    });

    test('resolves configured script paths from VCPKG_ROOT', () {
      final WindowsVcpkgPlatformAdapter configuredAdapter =
          WindowsVcpkgPlatformAdapter(
            configuration: const VcpkgUiConfiguration(
              fullInstallScriptPath: r'scripts\full install.cmd',
              removeAllScriptPath: r'D:\shared scripts\remove all.cmd',
            ),
          );

      final VcpkgLayout configuredLayout = configuredAdapter.createLayout(
        r'C:\vcpkg root',
      );

      expect(
        configuredLayout.fullInstallScriptPath,
        r'C:\vcpkg root\scripts\full install.cmd',
      );
      expect(
        configuredLayout.removeAllScriptPath,
        r'D:\shared scripts\remove all.cmd',
      );
    });

    test(
      'launches the full-install batch file from a root with spaces and metacharacters',
      () async {
        final Directory workspace = await Directory.systemTemp.createTemp(
          'vcpkg ui command test ',
        );
        addTearDown(() => workspace.delete(recursive: true));
        final Directory root = Directory(
          path.join(workspace.path, 'root with spaces & symbols'),
        );
        await root.create(recursive: true);

        final VcpkgLayout disposableLayout = adapter.createLayout(root.path);
        await File(disposableLayout.fullInstallScriptPath).writeAsString(
          '@echo off\r\n'
          'echo SAFE_BATCH_STARTED\r\n'
          'exit /B 0\r\n',
        );

        final result = await const ProcessRunner().run(
          adapter.fullInstallCommand(disposableLayout),
          captureOutput: true,
        );

        expect(result.succeeded, isTrue, reason: result.errorMessage);
        expect(result.capturedStdout, contains('SAFE_BATCH_STARTED'));

        await File(disposableLayout.removeAllScriptPath).writeAsString(
          '@echo off\r\n'
          'echo SAFE_REMOVE_ALL_STARTED\r\n'
          'exit /B 0\r\n',
        );
        final removeAllResult = await const ProcessRunner().run(
          adapter.removeAllCommand(disposableLayout),
          captureOutput: true,
        );

        expect(
          removeAllResult.succeeded,
          isTrue,
          reason: removeAllResult.errorMessage,
        );
        expect(
          removeAllResult.capturedStdout,
          contains('SAFE_REMOVE_ALL_STARTED'),
        );
      },
    );

    test('selects the default triplet from architecture or override', () {
      expect(adapter.defaultTriplet(const <String, String>{}), 'x64-windows');
      expect(
        adapter.defaultTriplet(const <String, String>{
          'PROCESSOR_ARCHITECTURE': 'ARM64',
        }),
        'arm64-windows',
      );
      expect(
        adapter.defaultTriplet(const <String, String>{
          'VCPKG_DEFAULT_TRIPLET': 'x64-windows-static',
        }),
        'x64-windows-static',
      );
    });

    test('chooses an application log directory outside VCPKG_ROOT', () {
      final String logDirectory = adapter.logDirectoryPath(
        const <String, String>{
          'LOCALAPPDATA': r'C:\Users\tester\AppData\Local',
        },
        layout: layout,
      );

      expect(logDirectory, isNot(startsWith(layout.rootDirectory)));
      expect(logDirectory, endsWith(r'VcpkgUI\logs'));
    });
  });

  test(
    'fake Linux adapter satisfies the common startup and command contract',
    () {
      final _FakeLinuxAdapter adapter = _FakeLinuxAdapter(
        validRoots: const <String>{'/workspace/vcpkg'},
      );
      final VcpkgRootValidator validator = VcpkgRootValidator(adapter);

      final VcpkgRootValidationResult valid = validator.validate(
        '/workspace/vcpkg',
      );
      expect(valid, isA<ValidVcpkgRoot>());
      final VcpkgLayout layout = (valid as ValidVcpkgRoot).layout;
      expect(layout.executablePath, '/workspace/vcpkg/vcpkg');
      expect(layout.fullInstallScriptPath, '/workspace/vcpkg/first-setup.sh');
      expect(adapter.defaultTriplet(const <String, String>{}), 'x64-linux');
      expect(adapter.listInstalledCommand(layout).arguments, <String>[
        'list',
        '--x-json',
      ]);
      expect(adapter.fullInstallCommand(layout).executable, '/bin/sh');
      expect(adapter.fullInstallCommand(layout).arguments, <String>[
        '/workspace/vcpkg/first-setup.sh',
      ]);
      expect(adapter.removeAllCommand(layout).arguments, <String>[
        '/workspace/vcpkg/remove-all.sh',
      ]);
      expect(adapter.upgradePreviewCommand(layout).arguments, <String>[
        'upgrade',
      ]);
      expect(adapter.upgradeAllCommand(layout).arguments, <String>[
        'upgrade',
        '--no-dry-run',
      ]);
      expect(
        adapter.logDirectoryPath(const <String, String>{}, layout: layout),
        '/tmp/vcpkg-ui/logs',
      );

      final VcpkgRootValidationResult invalid = validator.validate('/missing');
      expect(invalid, isA<InvalidVcpkgRoot>());
    },
  );
}

const VcpkgUiConfiguration _testConfiguration = VcpkgUiConfiguration(
  fullInstallScriptPath: 'first-setup-categorical.cmd',
  removeAllScriptPath: 'remove-all.cmd',
);

final class _FakeLinuxAdapter implements VcpkgPlatformAdapter {
  _FakeLinuxAdapter({required this.validRoots});

  final Set<String> validRoots;
  final path.Context _posix = path.Context(style: path.Style.posix);

  @override
  String get platformId => 'linux-fake';

  @override
  VcpkgLayout createLayout(String rawRoot) {
    final String root = _posix.normalize(_posix.absolute(rawRoot.trim()));
    return VcpkgLayout(
      rootDirectory: root,
      rootMarkerPath: _posix.join(root, '.vcpkg-root'),
      portsDirectory: _posix.join(root, 'ports'),
      executablePath: _posix.join(root, 'vcpkg'),
      removeAllScriptPath: _posix.join(root, 'remove-all.sh'),
      fullInstallScriptPath: _posix.join(root, 'first-setup.sh'),
    );
  }

  @override
  List<RequiredArtifact> requiredArtifacts(VcpkgLayout layout) =>
      <RequiredArtifact>[
        RequiredArtifact(
          code: 'root_directory_missing',
          path: layout.rootDirectory,
          kind: ArtifactKind.directory,
          description: 'fake Linux vcpkg root',
        ),
      ];

  @override
  List<ValidationIssue> validateLayout(VcpkgLayout layout) =>
      validRoots.contains(layout.rootDirectory)
      ? const <ValidationIssue>[]
      : <ValidationIssue>[
          ValidationIssue(
            code: 'root_directory_missing',
            message: 'fake Linux vcpkg root is missing',
            path: layout.rootDirectory,
          ),
        ];

  @override
  String defaultTriplet(Map<String, String> environment) => 'x64-linux';

  @override
  ProcessCommand listInstalledCommand(VcpkgLayout layout) =>
      _vcpkg(layout, const <String>['list', '--x-json']);

  @override
  ProcessCommand packageInfoCommand(VcpkgLayout layout, String packageName) =>
      _vcpkg(layout, <String>['x-package-info', packageName, '--x-json']);

  @override
  ProcessCommand installCommand(
    VcpkgLayout layout,
    PackageSpec specification,
  ) => _vcpkg(layout, <String>['install', specification.vcpkgArgument]);

  @override
  ProcessCommand removePreviewCommand(
    VcpkgLayout layout,
    PackageSpec specification,
  ) => _vcpkg(layout, <String>[
    'remove',
    specification.vcpkgArgument,
    '--dry-run',
  ]);

  @override
  ProcessCommand removeCommand(
    VcpkgLayout layout,
    PackageSpec specification, {
    required bool recurse,
  }) => _vcpkg(layout, <String>[
    'remove',
    specification.vcpkgArgument,
    if (recurse) '--recurse',
  ]);

  @override
  ProcessCommand removeAllCommand(VcpkgLayout layout) => ProcessCommand(
    executable: '/bin/sh',
    arguments: <String>[layout.removeAllScriptPath],
    workingDirectory: layout.rootDirectory,
  );

  @override
  ProcessCommand upgradePreviewCommand(VcpkgLayout layout) =>
      _vcpkg(layout, const <String>['upgrade']);

  @override
  ProcessCommand upgradeAllCommand(VcpkgLayout layout) =>
      _vcpkg(layout, const <String>['upgrade', '--no-dry-run']);

  @override
  ProcessCommand fullInstallCommand(VcpkgLayout layout) => ProcessCommand(
    executable: '/bin/sh',
    arguments: <String>[layout.fullInstallScriptPath],
    workingDirectory: layout.rootDirectory,
  );

  @override
  String logDirectoryPath(
    Map<String, String> environment, {
    VcpkgLayout? layout,
  }) => '/tmp/vcpkg-ui/logs';

  @override
  Future<void> openLogFile(String filePath) async {}

  ProcessCommand _vcpkg(VcpkgLayout layout, List<String> arguments) =>
      ProcessCommand(
        executable: layout.executablePath,
        arguments: arguments,
        workingDirectory: layout.rootDirectory,
        environment: <String, String>{'VCPKG_ROOT': layout.rootDirectory},
      );
}
