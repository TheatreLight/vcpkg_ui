import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_controller.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_gateway.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';
import 'package:vcpkg_ui/presentation/vcpkg_app.dart';

void main() {
  testWidgets('shows blocking startup diagnostics when VCPKG_ROOT is absent', (
    WidgetTester tester,
  ) async {
    final VcpkgUiController controller = VcpkgUiController(
      const _MissingRootGateway(),
    );

    await tester.pumpWidget(VcpkgApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('VCPKG_ROOT is not ready'), findsOneWidget);
    expect(find.text('<not set>'), findsOneWidget);
    expect(find.text('VCPKG_ROOT is not set.'), findsOneWidget);
    expect(find.text('Full installation'), findsOneWidget);
  });

  testWidgets('confirms and starts removal of all installed libraries', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _ReadyGateway gateway = _ReadyGateway();
    final VcpkgUiController controller = VcpkgUiController(gateway);

    await tester.pumpWidget(VcpkgApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Maintenance actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove all'));
    await tester.pumpAndSettle();
    expect(find.text('Remove all installed libraries?'), findsOneWidget);
    expect(gateway.removeAllCalls, 0);

    await tester.tap(find.widgetWithText(FilledButton, 'Remove all').last);
    await tester.pumpAndSettle();

    expect(gateway.removeAllCalls, 1);
  });

  testWidgets('previews and confirms update of all outdated libraries', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _ReadyGateway gateway = _ReadyGateway();
    final VcpkgUiController controller = VcpkgUiController(gateway);

    await tester.pumpWidget(VcpkgApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Maintenance actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update all'));
    await tester.pumpAndSettle();
    expect(find.text('Update 2 packages?'), findsOneWidget);
    expect(gateway.updatePreviewCalls, 1);
    expect(gateway.updateAllCalls, 0);

    await tester.tap(find.widgetWithText(FilledButton, 'Update all').last);
    await tester.pumpAndSettle();

    expect(gateway.updateAllCalls, 1);
  });

  testWidgets('checks vendor versions and reports the summary', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _ReadyGateway gateway = _ReadyGateway();
    final VcpkgUiController controller = VcpkgUiController(gateway);

    await tester.pumpWidget(VcpkgApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Maintenance actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check vendor versions'));
    await tester.pumpAndSettle();

    expect(gateway.vendorCheckCalls, 1);
    expect(
      find.textContaining('1 update(s), 1 current, 1 unresolved'),
      findsOneWidget,
    );
    expect(find.textContaining('2.0.0 (update available)'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Vendor updates'));
    await tester.pumpAndSettle();

    expect(find.text('alpha'), findsWidgets);
    expect(find.text('beta'), findsNothing);
    expect(find.text('custom'), findsNothing);
  });
}

final class _ReadyGateway implements VcpkgUiGateway {
  int removeAllCalls = 0;
  int updatePreviewCalls = 0;
  int updateAllCalls = 0;
  int vendorCheckCalls = 0;

  @override
  String? get environmentRoot => r'C:\fake\vcpkg';

  @override
  Future<StartupResult> initialize(VcpkgUiEventSink events) async {
    events.onRootValidated(environmentRoot!);
    return StartupSuccess(
      rawRoot: environmentRoot,
      rootPath: environmentRoot!,
      packages: <PackageUiModel>[
        _package('alpha'),
        _package('beta'),
        _package('custom'),
      ],
    );
  }

  PackageUiModel _package(String name) => PackageUiModel(
    package: PackageViewState(
      metadata: PortMetadata(
        name: name,
        availableVersion: '1.0.0',
        sourceVersion: '1.0.0',
        versionScheme: VcpkgVersionScheme.semver,
        manifestPath: '$environmentRoot\\ports\\$name\\vcpkg.json',
      ),
    ),
    triplet: 'x64-windows',
  );

  @override
  Future<OperationResult> removeAll(VcpkgUiEventSink events) async {
    removeAllCalls++;
    return const OperationResult(exitCode: 0);
  }

  @override
  Future<UpdatePreviewResult> previewUpdates(VcpkgUiEventSink events) async {
    updatePreviewCalls++;
    return const UpdatePreviewResult(
      summary: 'The following packages will be rebuilt:\n  * alpha@2.0',
      plannedPackages: <String>['alpha@2.0', 'beta@3.0'],
    );
  }

  @override
  Future<OperationResult> updateAll(VcpkgUiEventSink events) async {
    updateAllCalls++;
    return const OperationResult(exitCode: 0);
  }

  @override
  Future<VendorVersionScanResult> checkVendorVersions(
    VcpkgUiEventSink events,
  ) async {
    vendorCheckCalls++;
    events.onVendorVersionProgress(
      const VendorVersionCheckProgress(completed: 3, total: 3),
    );
    return VendorVersionScanResult(
      packages: <String, VendorVersionInfo>{
        'alpha': const VendorVersionInfo(
          packageName: 'alpha',
          status: VendorVersionStatus.updateAvailable,
          localVersion: '1.0.0',
          vendorVersion: '2.0.0',
        ),
        'beta': const VendorVersionInfo(
          packageName: 'beta',
          status: VendorVersionStatus.current,
          localVersion: '1.0.0',
          vendorVersion: '1.0.0',
        ),
        'custom': const VendorVersionInfo(
          packageName: 'custom',
          status: VendorVersionStatus.unsupported,
          localVersion: '1.0.0',
          reason: 'Custom source.',
        ),
      },
    );
  }

  @override
  Future<List<PackageUiModel>> refreshCatalog(VcpkgUiEventSink events) async =>
      const <PackageUiModel>[];

  @override
  Future<void> openLogFile(String logPath) async {}

  @override
  Future<OperationResult> install(
    PackageUiModel package,
    VcpkgUiEventSink events,
  ) => throw UnsupportedError('unused');

  @override
  Future<RemovePreviewResult> previewRemove(
    PackageUiModel package,
    VcpkgUiEventSink events,
  ) => throw UnsupportedError('unused');

  @override
  Future<OperationResult> remove(
    PackageUiModel package, {
    required bool recurse,
    required VcpkgUiEventSink events,
  }) => throw UnsupportedError('unused');

  @override
  Future<OperationResult> runFullInstallation(VcpkgUiEventSink events) =>
      throw UnsupportedError('unused');
}

final class _MissingRootGateway implements VcpkgUiGateway {
  const _MissingRootGateway();

  @override
  String? get environmentRoot => null;

  @override
  Future<StartupResult> initialize(VcpkgUiEventSink events) async =>
      const StartupFailure(rawRoot: null, reason: 'VCPKG_ROOT is not set.');

  @override
  Future<void> openLogFile(String logPath) async {}

  @override
  Future<List<PackageUiModel>> refreshCatalog(VcpkgUiEventSink events) =>
      throw UnsupportedError('unused');

  @override
  Future<OperationResult> install(
    PackageUiModel package,
    VcpkgUiEventSink events,
  ) => throw UnsupportedError('unused');

  @override
  Future<RemovePreviewResult> previewRemove(
    PackageUiModel package,
    VcpkgUiEventSink events,
  ) => throw UnsupportedError('unused');

  @override
  Future<OperationResult> remove(
    PackageUiModel package, {
    required bool recurse,
    required VcpkgUiEventSink events,
  }) => throw UnsupportedError('unused');

  @override
  Future<OperationResult> removeAll(VcpkgUiEventSink events) =>
      throw UnsupportedError('unused');

  @override
  Future<UpdatePreviewResult> previewUpdates(VcpkgUiEventSink events) =>
      throw UnsupportedError('unused');

  @override
  Future<OperationResult> updateAll(VcpkgUiEventSink events) =>
      throw UnsupportedError('unused');

  @override
  Future<VendorVersionScanResult> checkVendorVersions(
    VcpkgUiEventSink events,
  ) => throw UnsupportedError('unused');

  @override
  Future<OperationResult> runFullInstallation(VcpkgUiEventSink events) =>
      throw UnsupportedError('unused');
}
