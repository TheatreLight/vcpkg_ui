import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/application/jsonc_parser.dart';
import 'package:vcpkg_ui/application/vcpkg_root_validator.dart';
import 'package:vcpkg_ui/application/vcpkg_ui_config.dart';
import 'package:vcpkg_ui/application/vendor_version_config.dart';
import 'package:vcpkg_ui/infrastructure/platform/windows_vcpkg_platform_adapter.dart';

void main() {
  test('JSONC parser preserves comment-like text inside strings', () {
    final Object? decoded = decodeJsonc(r'''
{
  // A line comment.
  "url": "https://example.test/path//file",
  /* A block
     comment. */
  "value": 1
}
''');

    expect(decoded, <String, Object?>{
      'url': 'https://example.test/path//file',
      'value': 1,
    });
  });

  test('loads configured script paths from a commented file', () async {
    final Directory workspace = await Directory.systemTemp.createTemp(
      'vcpkg-ui-config-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final File config = File(path.join(workspace.path, 'vcpkg-ui.jsonc'));
    await config.writeAsString(r'''
{
  // Paths may be relative to VCPKG_ROOT.
  "schema": 1,
  "scripts": {
    "fullInstall": "scripts/full install.cmd",
    "removeAll": "scripts/remove all.cmd"
  }
}
''');

    final VcpkgUiConfiguration result = VcpkgUiConfigLoader(
      config.path,
    ).loadSync();

    expect(result.fullInstallScriptPath, 'scripts/full install.cmd');
    expect(result.removeAllScriptPath, 'scripts/remove all.cmd');
  });

  test('reports a missing or malformed application config', () async {
    final Directory workspace = await Directory.systemTemp.createTemp(
      'vcpkg-ui-invalid-config-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final String missing = path.join(workspace.path, 'missing.jsonc');

    expect(
      () => VcpkgUiConfigLoader(missing).loadSync(),
      throwsA(
        isA<VcpkgUiConfigException>().having(
          (VcpkgUiConfigException error) => error.message,
          'message',
          contains('does not exist'),
        ),
      ),
    );

    final File invalid = File(path.join(workspace.path, 'invalid.jsonc'));
    await invalid.writeAsString(
      '{"schema":1,"scripts":{"fullInstall":"setup.cmd"}}',
    );
    expect(
      () => VcpkgUiConfigLoader(invalid.path).loadSync(),
      throwsA(
        isA<VcpkgUiConfigException>().having(
          (VcpkgUiConfigException error) => error.message,
          'message',
          contains('scripts.removeAll'),
        ),
      ),
    );
  });

  test('startup validation reports an application config error', () async {
    final Directory workspace = await Directory.systemTemp.createTemp(
      'vcpkg-ui-missing-config-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final String missing = path.join(workspace.path, 'missing.jsonc');
    final WindowsVcpkgPlatformAdapter adapter = WindowsVcpkgPlatformAdapter(
      configurationLoader: VcpkgUiConfigLoader(missing),
    );

    final VcpkgRootValidationResult result = VcpkgRootValidator(
      adapter,
    ).validate(workspace.path);

    expect(result, isA<InvalidVcpkgRoot>());
    final InvalidVcpkgRoot invalid = result as InvalidVcpkgRoot;
    expect(invalid.issues.single.code, 'application_config_invalid');
    expect(invalid.message, contains('vcpkg-ui.example.jsonc'));
  });

  test('environment override selects the application config path', () {
    final String result = VcpkgUiConfigLoader.locate(
      environment: const <String, String>{
        'VCPKG_UI_CONFIG': 'custom/settings.jsonc',
      },
      currentDirectory: Directory.current.path,
    );

    expect(result, path.normalize(path.absolute('custom/settings.jsonc')));
  });

  test('tracked JSONC templates remain valid', () async {
    final String configDirectory = path.join(Directory.current.path, 'config');

    final VcpkgUiConfiguration application = VcpkgUiConfigLoader(
      path.join(configDirectory, 'vcpkg-ui.example.jsonc'),
    ).loadSync();
    final VendorVersionConfiguration vendors = await VendorVersionConfigLoader(
      path.join(configDirectory, 'vendor-version-sources.example.jsonc'),
    ).load();

    expect(application.fullInstallScriptPath, isNotEmpty);
    expect(application.removeAllScriptPath, isNotEmpty);
    expect(vendors.packages, hasLength(5));
    expect(
      vendors.packages.values.whereType<InvalidVendorVersionRule>(),
      isEmpty,
    );
  });
}
