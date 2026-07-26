import 'dart:io';

import 'package:vcpkg_ui/application/full_install_plan_reader.dart';
import 'package:vcpkg_ui/application/progress_parser.dart';
import 'package:vcpkg_ui/application/vcpkg_ui_config.dart';
import 'package:vcpkg_ui/app/default_vcpkg_ui_gateway.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_controller.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_gateway.dart';
import 'package:vcpkg_ui/app/window_close_guard.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';
import 'package:vcpkg_ui/infrastructure/platform/windows_vcpkg_platform_adapter.dart';

VcpkgUiController createVcpkgUiController({Map<String, String>? environment}) {
  final Map<String, String> effectiveEnvironment =
      environment ?? Platform.environment;
  final VcpkgUiGateway gateway;
  if (Platform.isWindows) {
    gateway = DefaultVcpkgUiGateway(
      WindowsVcpkgPlatformAdapter(
        environment: effectiveEnvironment,
        configurationLoader: VcpkgUiConfigLoader(
          VcpkgUiConfigLoader.locate(environment: effectiveEnvironment),
        ),
      ),
      const WindowsBatchFullInstallPlanReader(),
      WindowsVcpkgProgressParser.new,
      environment: effectiveEnvironment,
    );
  } else {
    gateway = _UnsupportedPlatformGateway(
      environmentRoot: effectiveEnvironment['VCPKG_ROOT'],
    );
  }
  return VcpkgUiController(gateway, const MethodChannelWindowCloseGuard());
}

final class _UnsupportedPlatformGateway implements VcpkgUiGateway {
  const _UnsupportedPlatformGateway({required this.environmentRoot});

  @override
  final String? environmentRoot;

  Never _unsupported() => throw UnsupportedError(
    'This build contains only the Windows platform adapter.',
  );

  @override
  Future<StartupResult> initialize(VcpkgUiEventSink events) async =>
      StartupFailure(
        rawRoot: environmentRoot,
        reason: 'This build contains only the Windows platform adapter.',
      );

  @override
  Future<List<PackageUiModel>> refreshCatalog(VcpkgUiEventSink events) async =>
      _unsupported();

  @override
  Future<OperationResult> install(
    PackageUiModel package,
    VcpkgUiEventSink events,
  ) async => _unsupported();

  @override
  Future<RemovePreviewResult> previewRemove(
    PackageUiModel package,
    VcpkgUiEventSink events,
  ) async => _unsupported();

  @override
  Future<OperationResult> remove(
    PackageUiModel package, {
    required bool recurse,
    required VcpkgUiEventSink events,
  }) async => _unsupported();

  @override
  Future<OperationResult> removeAll(VcpkgUiEventSink events) async =>
      _unsupported();

  @override
  Future<UpdatePreviewResult> previewUpdates(VcpkgUiEventSink events) async =>
      _unsupported();

  @override
  Future<OperationResult> updateAll(VcpkgUiEventSink events) async =>
      _unsupported();

  @override
  Future<VendorVersionScanResult> checkVendorVersions(
    VcpkgUiEventSink events,
  ) async => _unsupported();

  @override
  Future<OperationResult> runFullInstallation(VcpkgUiEventSink events) async =>
      _unsupported();

  @override
  Future<void> openLogFile(String logPath) async => _unsupported();
}
