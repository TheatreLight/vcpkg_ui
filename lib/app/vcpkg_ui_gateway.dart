import 'package:vcpkg_ui/domain/output_models.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/domain/progress_models.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';

/// Presentation-ready package data assembled by the application layer.
final class PackageUiModel {
  const PackageUiModel({
    required this.package,
    required this.triplet,
    this.installSpecification,
    this.removeSpecification,
    this.installBlockedReason,
  });

  final PackageViewState package;
  final String triplet;
  final PackageSpec? installSpecification;
  final PackageSpec? removeSpecification;
  final String? installBlockedReason;

  String get name => package.metadata.name;
}

sealed class StartupResult {
  const StartupResult({required this.rawRoot});

  final String? rawRoot;
}

final class StartupSuccess extends StartupResult {
  const StartupSuccess({
    required super.rawRoot,
    required this.rootPath,
    required this.packages,
  });

  final String rootPath;
  final List<PackageUiModel> packages;
}

final class StartupFailure extends StartupResult {
  const StartupFailure({required super.rawRoot, required this.reason});

  final String reason;
}

final class RemovePreviewResult {
  const RemovePreviewResult({
    required this.summary,
    this.dependentPackages = const <String>[],
  });

  final String summary;
  final List<String> dependentPackages;

  bool get requiresRecursiveRemoval => dependentPackages.isNotEmpty;
}

final class UpdatePreviewResult {
  const UpdatePreviewResult({
    required this.summary,
    this.plannedPackages = const <String>[],
  });

  final String summary;
  final List<String> plannedPackages;

  bool get hasUpdates => plannedPackages.isNotEmpty;
}

final class OperationResult {
  const OperationResult({
    required this.exitCode,
    this.logPath,
    this.errorMessage,
  });

  final int exitCode;
  final String? logPath;
  final String? errorMessage;

  bool get succeeded => exitCode == 0 && errorMessage == null;
}

/// Event sink used by the backend to stream process state without exposing
/// platform or process details to Flutter widgets.
abstract interface class VcpkgUiEventSink {
  void onRootValidated(String rootPath);

  void onOperationRunning({String? logPath});

  void onOutput(OutputLine line);

  void onProgress(ProgressSnapshot snapshot);

  void onVendorVersionProgress(VendorVersionCheckProgress progress);
}

/// Narrow boundary between the platform-neutral UI and application services.
abstract interface class VcpkgUiGateway {
  String? get environmentRoot;

  Future<StartupResult> initialize(VcpkgUiEventSink events);

  Future<List<PackageUiModel>> refreshCatalog(VcpkgUiEventSink events);

  Future<OperationResult> install(
    PackageUiModel package,
    VcpkgUiEventSink events,
  );

  Future<RemovePreviewResult> previewRemove(
    PackageUiModel package,
    VcpkgUiEventSink events,
  );

  Future<OperationResult> remove(
    PackageUiModel package, {
    required bool recurse,
    required VcpkgUiEventSink events,
  });

  Future<OperationResult> removeAll(VcpkgUiEventSink events);

  Future<UpdatePreviewResult> previewUpdates(VcpkgUiEventSink events);

  Future<OperationResult> updateAll(VcpkgUiEventSink events);

  Future<VendorVersionScanResult> checkVendorVersions(VcpkgUiEventSink events);

  Future<OperationResult> runFullInstallation(VcpkgUiEventSink events);

  Future<void> openLogFile(String logPath);
}
