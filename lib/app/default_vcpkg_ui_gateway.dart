import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/application/full_install_plan_reader.dart';
import 'package:vcpkg_ui/application/package_catalog_service.dart';
import 'package:vcpkg_ui/application/package_spec_resolver.dart';
import 'package:vcpkg_ui/application/port_upstream_source_reader.dart';
import 'package:vcpkg_ui/application/vendor_version_log_formatter.dart';
import 'package:vcpkg_ui/application/vendor_version_config.dart';
import 'package:vcpkg_ui/application/vendor_version_service.dart';
import 'package:vcpkg_ui/application/vcpkg_operation_service.dart';
import 'package:vcpkg_ui/application/vcpkg_root_validator.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_gateway.dart';
import 'package:vcpkg_ui/domain/operation_models.dart';
import 'package:vcpkg_ui/domain/output_models.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';
import 'package:vcpkg_ui/infrastructure/logging/log_store.dart';
import 'package:vcpkg_ui/infrastructure/platform/vcpkg_platform_adapter.dart';
import 'package:vcpkg_ui/infrastructure/process/process_runner.dart';
import 'package:vcpkg_ui/infrastructure/vendor/github_vendor_api.dart';
import 'package:vcpkg_ui/infrastructure/vendor/configured_vendor_api.dart';
import 'package:vcpkg_ui/infrastructure/vendor/vendor_version_cache.dart';

final class DefaultVcpkgUiGateway implements VcpkgUiGateway {
  DefaultVcpkgUiGateway(
    this._adapter,
    this._planReader,
    this._progressParserFactory, {
    Map<String, String>? environment,
    this._runner = const ProcessRunner(),
    VendorVersionService? vendorVersionService,
    String? vendorVersionConfigPath,
  }) : _environment = Map<String, String>.unmodifiable(
         environment ?? Platform.environment,
       ),
       _providedVendorVersionService = vendorVersionService,
       _providedVendorVersionConfigPath = vendorVersionConfigPath;

  final VcpkgPlatformAdapter _adapter;
  final FullInstallPlanReader _planReader;
  final ProgressParserFactory _progressParserFactory;
  final Map<String, String> _environment;
  final ProcessRunner _runner;
  final VendorVersionService? _providedVendorVersionService;
  final String? _providedVendorVersionConfigPath;

  VcpkgUiEventSink? _events;
  PackageCatalogService? _catalogService;
  PackageSpecResolver? _specificationResolver;
  VcpkgOperationService? _operationService;
  VendorVersionService? _vendorVersionService;
  String? _vendorVersionConfigPath;
  LogStore? _logStore;
  FullInstallPlan? _fullInstallPlan;
  RemovePreview? _pendingRemovePreview;
  UpdatePreview? _pendingUpdatePreview;
  List<PackageUiModel> _packages = const <PackageUiModel>[];
  bool _catalogWasRefreshedByOperation = false;

  @override
  String? get environmentRoot => _environment['VCPKG_ROOT'];

  @override
  Future<StartupResult> initialize(VcpkgUiEventSink events) async {
    _events = events;
    final VcpkgRootValidationResult validation = VcpkgRootValidator(
      _adapter,
    ).validate(environmentRoot);
    if (validation case InvalidVcpkgRoot()) {
      return StartupFailure(
        rawRoot: validation.rawRoot,
        reason: validation.message,
      );
    }

    final ValidVcpkgRoot valid = validation as ValidVcpkgRoot;
    events.onRootValidated(valid.layout.rootDirectory);

    try {
      final FullInstallPlan plan = await _planReader.read(
        valid.layout.fullInstallScriptPath,
      );
      _fullInstallPlan = plan;
      _specificationResolver = PackageSpecResolver(plan);
      _catalogService = PackageCatalogService(
        adapter: _adapter,
        runner: _runner,
        layout: valid.layout,
      );
      final String logDirectory = _adapter.logDirectoryPath(
        _environment,
        layout: valid.layout,
      );
      final LogStore logStore = LogStore(logDirectory);
      _logStore = logStore;
      final VendorVersionCache vendorCache = VendorVersionCache(
        filePath: VendorVersionCache.defaultFilePath(
          path.dirname(logDirectory),
        ),
      );
      final String vendorConfigPath =
          _providedVendorVersionConfigPath ??
          VendorVersionConfigLoader.locate(environment: _environment);
      _vendorVersionConfigPath = vendorConfigPath;
      _vendorVersionService =
          _providedVendorVersionService ??
          VendorVersionService(
            sourceReader: const PortUpstreamSourceReader(),
            githubClient: GithubVendorApi(
              cache: vendorCache,
              environment: _environment,
            ),
            configurationLoader: VendorVersionConfigLoader(vendorConfigPath),
            configuredClient: ConfiguredVendorApi(
              cache: vendorCache,
              environment: _environment,
            ),
          );
      _operationService = VcpkgOperationService(
        adapter: _adapter,
        layout: valid.layout,
        runner: _runner,
        logStore: logStore,
        planReader: _planReader,
        progressParserFactory: _progressParserFactory,
        coordinator: OperationCoordinator(
          onStateChanged: _onOperationStateChanged,
        ),
        onOutput: (OutputLine line) => _events?.onOutput(line),
        onProgress: (snapshot) => _events?.onProgress(snapshot),
        refreshCatalog: _refreshCatalogForOperation,
      );
      _packages = await _loadPackageModels();
      for (final String warning in plan.warnings) {
        _emitSystem(warning);
      }
      return StartupSuccess(
        rawRoot: valid.rawRoot,
        rootPath: valid.layout.rootDirectory,
        packages: _packages,
      );
    } on Object catch (error) {
      return StartupFailure(
        rawRoot: valid.rawRoot,
        reason: 'Vcpkg initialization failed: $error',
      );
    }
  }

  @override
  Future<List<PackageUiModel>> refreshCatalog(VcpkgUiEventSink events) async {
    _events = events;
    if (_catalogWasRefreshedByOperation) {
      _catalogWasRefreshedByOperation = false;
      return _packages;
    }
    _packages = await _loadPackageModels();
    return _packages;
  }

  @override
  Future<OperationResult> install(
    PackageUiModel package,
    VcpkgUiEventSink events,
  ) async {
    _events = events;
    final PackageSpec? specification = package.installSpecification;
    if (specification == null) {
      throw StateError(
        package.installBlockedReason ??
            'No install specification is available for ${package.name}.',
      );
    }
    final result = await _requireOperationService().install(specification);
    return _operationResult(result);
  }

  @override
  Future<RemovePreviewResult> previewRemove(
    PackageUiModel package,
    VcpkgUiEventSink events,
  ) async {
    _events = events;
    final PackageSpec? specification = package.removeSpecification;
    if (specification == null) {
      throw StateError('No installed package is selected for removal.');
    }
    final RemovePreview preview = await _requireOperationService()
        .previewRemove(specification);
    _pendingRemovePreview = preview;
    final List<String> dependents = preview.affectedPackages
        .where((PackageSpec item) => item != preview.specification)
        .map((PackageSpec item) => item.vcpkgArgument)
        .toList(growable: false);
    final String combinedOutput = <String>[
      preview.processResult.capturedStdout,
      preview.processResult.capturedStderr,
    ].where((String value) => value.trim().isNotEmpty).join('\n');
    return RemovePreviewResult(
      summary: combinedOutput.isEmpty
          ? 'vcpkg dry-run completed successfully.'
          : combinedOutput,
      dependentPackages: dependents,
    );
  }

  @override
  Future<OperationResult> remove(
    PackageUiModel package, {
    required bool recurse,
    required VcpkgUiEventSink events,
  }) async {
    _events = events;
    final RemovePreview? preview = _pendingRemovePreview;
    if (preview == null ||
        preview.specification != package.removeSpecification) {
      throw StateError('Run and confirm remove preview first.');
    }
    try {
      final result = await _requireOperationService().remove(
        preview,
        confirmedRecursiveRemoval: recurse,
      );
      return _operationResult(result);
    } finally {
      _pendingRemovePreview = null;
    }
  }

  @override
  Future<OperationResult> removeAll(VcpkgUiEventSink events) async {
    _events = events;
    final result = await _requireOperationService().removeAll();
    return _operationResult(result);
  }

  @override
  Future<UpdatePreviewResult> previewUpdates(VcpkgUiEventSink events) async {
    _events = events;
    final UpdatePreview preview = await _requireOperationService()
        .previewUpdates();
    _pendingUpdatePreview = preview;
    final String combinedOutput = <String>[
      preview.processResult.capturedStdout,
      preview.processResult.capturedStderr,
    ].where((String value) => value.trim().isNotEmpty).join('\n');
    return UpdatePreviewResult(
      summary: combinedOutput.isEmpty
          ? 'vcpkg upgrade dry-run completed without output.'
          : combinedOutput,
      plannedPackages: preview.plannedPackages,
    );
  }

  @override
  Future<OperationResult> updateAll(VcpkgUiEventSink events) async {
    _events = events;
    final UpdatePreview? preview = _pendingUpdatePreview;
    if (preview == null) {
      throw StateError('Run and confirm the update preview first.');
    }
    try {
      final result = await _requireOperationService().updateAll(preview);
      return _operationResult(result);
    } finally {
      _pendingUpdatePreview = null;
    }
  }

  @override
  Future<VendorVersionScanResult> checkVendorVersions(
    VcpkgUiEventSink events,
  ) async {
    _events = events;
    final OperationLog log = await _requireLogStore().create(
      OperationKind.vendorVersionCheck,
    );
    const VendorVersionLogFormatter formatter = VendorVersionLogFormatter();
    _writeVendorLogLine(
      log,
      'Vendor version check started for full-install packages. '
      'Config: ${_vendorVersionConfigPath ?? 'not configured'}.',
    );
    try {
      final VendorVersionScanResult result =
          await _requireVendorVersionService().check(
            plan: _requireFullInstallPlan(),
            catalog: _packages.map((PackageUiModel item) => item.package),
            onProgress: events.onVendorVersionProgress,
          );
      final VendorVersionScanResult resultWithLog = VendorVersionScanResult(
        packages: result.packages,
        logPath: log.path,
      );
      for (final String detail in formatter.details(resultWithLog)) {
        _writeVendorLogLine(log, detail);
      }
      _writeVendorLogLine(
        log,
        formatter.summary(resultWithLog),
        emitToOutput: false,
      );
      return resultWithLog;
    } on Object catch (error) {
      _writeVendorLogLine(log, 'Vendor version check aborted: $error');
      rethrow;
    } finally {
      await log.close();
    }
  }

  @override
  Future<OperationResult> runFullInstallation(VcpkgUiEventSink events) async {
    _events = events;
    final FullInstallExecution execution = await _requireOperationService()
        .fullInstall();
    return _operationResult(execution.result);
  }

  @override
  Future<void> openLogFile(String logPath) => _adapter.openLogFile(logPath);

  Future<List<PackageUiModel>> _loadPackageModels() async {
    final PackageCatalogService catalog = _requireCatalogService();
    final PackageSpecResolver resolver = _requireSpecificationResolver();
    final String defaultTriplet = _adapter.defaultTriplet(_environment);
    final List<PackageViewState> packages = await catalog.load();
    final List<PackageUiModel> result = <PackageUiModel>[];
    for (final PackageViewState package in packages) {
      final InstalledPackage? installed = package.installed.isEmpty
          ? null
          : package.installed.first;
      final String triplet = installed?.triplet ?? defaultTriplet;
      PackageSpec? installSpecification;
      String? blockedReason;
      try {
        installSpecification = resolver.forInstall(
          package.metadata.name,
          defaultTriplet,
        );
      } on UnresolvedConditionalTargetException catch (error) {
        blockedReason = error.toString();
      }
      result.add(
        PackageUiModel(
          package: package,
          triplet: triplet,
          installSpecification: installSpecification,
          removeSpecification: installed == null
              ? null
              : PackageSpec(name: installed.name, triplet: installed.triplet),
          installBlockedReason: blockedReason,
        ),
      );
      if (package.metadata.metadataError case final String error) {
        _emitSystem('${package.metadata.name}: $error');
      }
    }
    return List<PackageUiModel>.unmodifiable(result);
  }

  Future<void> _refreshCatalogForOperation() async {
    _packages = await _loadPackageModels();
    _catalogWasRefreshedByOperation = true;
  }

  void _onOperationStateChanged(OperationState state) {
    if (state.phase == OperationPhase.running) {
      _events?.onOperationRunning(logPath: state.logPath);
    }
  }

  void _emitSystem(String message) {
    _events?.onOutput(
      OutputLine(
        source: OutputSource.system,
        text: message,
        timestamp: DateTime.now(),
      ),
    );
  }

  void _writeVendorLogLine(
    OperationLog log,
    String message, {
    bool emitToOutput = true,
  }) {
    final OutputLine line = OutputLine(
      source: OutputSource.system,
      text: message,
      timestamp: DateTime.now(),
    );
    log.write(line);
    if (emitToOutput) {
      _events?.onOutput(line);
    }
  }

  OperationResult _operationResult(ProcessRunResult result) => OperationResult(
    exitCode: result.exitCode ?? -1,
    logPath: result.logPath,
    errorMessage: result.succeeded
        ? null
        : result.errorMessage ??
              (result.started
                  ? 'Process exited with code ${result.exitCode}.'
                  : 'Process could not be started.'),
  );

  PackageCatalogService _requireCatalogService() =>
      _catalogService ??
      (throw StateError('The vcpkg catalog has not been initialized.'));

  PackageSpecResolver _requireSpecificationResolver() =>
      _specificationResolver ??
      (throw StateError('The package plan has not been initialized.'));

  VcpkgOperationService _requireOperationService() =>
      _operationService ??
      (throw StateError('Vcpkg operations have not been initialized.'));

  VendorVersionService _requireVendorVersionService() =>
      _vendorVersionService ??
      (throw StateError('Vendor version checks have not been initialized.'));

  LogStore _requireLogStore() =>
      _logStore ?? (throw StateError('Logging has not been initialized.'));

  FullInstallPlan _requireFullInstallPlan() =>
      _fullInstallPlan ??
      (throw StateError('The full-install plan has not been initialized.'));
}
