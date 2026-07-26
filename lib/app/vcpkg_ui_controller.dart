import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:vcpkg_ui/application/regex_filter.dart';
import 'package:vcpkg_ui/application/vendor_version_log_formatter.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_gateway.dart';
import 'package:vcpkg_ui/app/window_close_guard.dart';
import 'package:vcpkg_ui/domain/operation_models.dart';
import 'package:vcpkg_ui/domain/output_models.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/domain/progress_models.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';

enum StartupUiPhase { validating, loading, invalid, ready }

final class VcpkgUiController extends ChangeNotifier
    implements VcpkgUiEventSink {
  VcpkgUiController(
    this._gateway, [
    this._windowCloseGuard = const NoopWindowCloseGuard(),
  ]);

  static const int _maximumOutputLines = 5000;

  final VcpkgUiGateway _gateway;
  final WindowCloseGuard _windowCloseGuard;
  final List<PackageUiModel> _packages = <PackageUiModel>[];
  final List<PackageUiModel> _filteredPackages = <PackageUiModel>[];
  final List<OutputLine> _output = <OutputLine>[];
  final Map<String, VendorVersionInfo> _vendorVersions =
      <String, VendorVersionInfo>{};

  StartupUiPhase _startupPhase = StartupUiPhase.validating;
  String? _rootPath;
  String? _startupError;
  String _searchPattern = '';
  String? _searchError;
  PackageUiModel? _selectedPackage;
  OperationState _operation = const OperationState();
  ProgressSnapshot? _progress;
  bool _outputExpanded = false;
  bool _initialized = false;
  bool _nativeCloseGuardEnabled = false;
  bool _vendorUpdatesOnly = false;
  String? _latestLogPath;
  VendorVersionCheckState _vendorVersionCheck = const VendorVersionCheckState();

  StartupUiPhase get startupPhase => _startupPhase;
  String? get environmentRoot => _gateway.environmentRoot;
  String? get rootPath => _rootPath;
  String? get startupError => _startupError;
  String get searchPattern => _searchPattern;
  String? get searchError => _searchError;
  PackageUiModel? get selectedPackage => _selectedPackage;
  OperationState get operation => _operation;
  ProgressSnapshot? get progress => _progress;
  bool get outputExpanded => _outputExpanded;
  bool get isOperationActive => _operation.isActive;
  bool get isVendorVersionCheckActive => _vendorVersionCheck.isActive;
  bool get canRunOperations =>
      _startupPhase == StartupUiPhase.ready &&
      !isOperationActive &&
      !isVendorVersionCheckActive;
  bool get canCheckVendorVersions => canRunOperations;
  bool get vendorUpdatesOnly => _vendorUpdatesOnly;
  bool get hasVendorVersionResults => _vendorVersions.isNotEmpty;
  String? get latestLogPath => _latestLogPath;
  VendorVersionCheckState get vendorVersionCheck => _vendorVersionCheck;

  UnmodifiableListView<PackageUiModel> get packages =>
      UnmodifiableListView<PackageUiModel>(_filteredPackages);
  UnmodifiableListView<OutputLine> get output =>
      UnmodifiableListView<OutputLine>(_output);

  VendorVersionInfo? vendorVersionFor(String packageName) =>
      _vendorVersions[packageName.toLowerCase()];

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _startupPhase = StartupUiPhase.validating;
    notifyListeners();

    try {
      final StartupResult result = await _gateway.initialize(this);
      switch (result) {
        case StartupSuccess():
          _rootPath = result.rootPath;
          _replacePackages(result.packages);
          _startupPhase = StartupUiPhase.ready;
        case StartupFailure():
          _startupError = result.reason;
          _startupPhase = StartupUiPhase.invalid;
      }
    } on Object catch (error) {
      _startupError = error.toString();
      _startupPhase = StartupUiPhase.invalid;
    }
    notifyListeners();
  }

  void updateSearch(String pattern) {
    _searchPattern = pattern;
    _applyFilter();
    notifyListeners();
  }

  void setVendorUpdatesOnly(bool value) {
    _vendorUpdatesOnly = value && hasVendorVersionResults;
    _applyFilter();
    notifyListeners();
  }

  void selectPackage(PackageUiModel package) {
    _selectedPackage = package;
    notifyListeners();
  }

  void toggleOutput() {
    _outputExpanded = !_outputExpanded;
    notifyListeners();
  }

  void clearOutput() {
    _output.clear();
    notifyListeners();
  }

  Future<void> openLogFile() async {
    final String? path = _latestLogPath;
    if (path == null) {
      return;
    }
    try {
      await _gateway.openLogFile(path);
    } on Object catch (error) {
      onOutput(
        OutputLine(
          source: OutputSource.system,
          text: 'Could not open log file: $error',
          timestamp: DateTime.now(),
        ),
      );
      _outputExpanded = true;
      notifyListeners();
    }
  }

  Future<void> installSelected() async {
    final PackageUiModel? package = _selectedPackage;
    if (package == null || !canRunOperations) {
      return;
    }
    final String? blockedReason = package.installBlockedReason;
    if (blockedReason != null) {
      await _publishLocalFailure(
        OperationKind.install,
        blockedReason,
        target: _displaySpecification(package),
      );
      return;
    }
    await _runOperation(
      OperationKind.install,
      () => _gateway.install(package, this),
      target: package.installSpecification ?? _displaySpecification(package),
    );
  }

  Future<RemovePreviewResult?> previewRemoveSelected() async {
    final PackageUiModel? package = _selectedPackage;
    if (package == null || !canRunOperations || !package.package.isInstalled) {
      return null;
    }
    final PackageSpec target =
        package.removeSpecification ?? _displaySpecification(package);
    await _beginOperation(OperationKind.removePreview, target: target);
    try {
      final RemovePreviewResult preview = await _gateway.previewRemove(
        package,
        this,
      );
      await _completeOperation(
        const OperationResult(exitCode: 0),
        OperationKind.removePreview,
        target: target,
      );
      return preview;
    } on Object catch (error) {
      await _publishLocalFailure(
        OperationKind.removePreview,
        error.toString(),
        target: target,
      );
      return null;
    }
  }

  Future<void> removeSelected({required bool recurse}) async {
    final PackageUiModel? package = _selectedPackage;
    if (package == null || !canRunOperations || !package.package.isInstalled) {
      return;
    }
    await _runOperation(
      OperationKind.remove,
      () => _gateway.remove(package, recurse: recurse, events: this),
      target: package.removeSpecification ?? _displaySpecification(package),
    );
  }

  Future<void> removeAllInstalled() async {
    if (!canRunOperations) {
      return;
    }
    await _runOperation(
      OperationKind.removeAll,
      () => _gateway.removeAll(this),
    );
  }

  Future<UpdatePreviewResult?> previewUpdates() async {
    if (!canRunOperations) {
      return null;
    }
    await _beginOperation(OperationKind.updatePreview);
    try {
      final UpdatePreviewResult preview = await _gateway.previewUpdates(this);
      await _completeOperation(
        const OperationResult(exitCode: 0),
        OperationKind.updatePreview,
      );
      return preview;
    } on Object catch (error) {
      await _publishLocalFailure(OperationKind.updatePreview, error.toString());
      return null;
    }
  }

  Future<void> updateAll() async {
    if (!canRunOperations) {
      return;
    }
    await _runOperation(
      OperationKind.updateAll,
      () => _gateway.updateAll(this),
    );
  }

  Future<VendorVersionScanResult?> checkVendorVersions() async {
    if (!canCheckVendorVersions) {
      return null;
    }
    _vendorVersionCheck = const VendorVersionCheckState(
      phase: VendorVersionCheckPhase.running,
    );
    notifyListeners();
    try {
      final VendorVersionScanResult result = await _gateway.checkVendorVersions(
        this,
      );
      _vendorVersions
        ..clear()
        ..addAll(result.packages);
      _latestLogPath = result.logPath ?? _latestLogPath;
      _vendorVersionCheck = VendorVersionCheckState(
        phase: VendorVersionCheckPhase.completed,
        completed: result.checkedCount,
        total: result.checkedCount,
      );
      _applyFilter();
      onOutput(
        OutputLine(
          source: OutputSource.system,
          text: const VendorVersionLogFormatter().summary(result),
          timestamp: DateTime.now(),
        ),
      );
      notifyListeners();
      return result;
    } on Object catch (error) {
      _vendorVersionCheck = VendorVersionCheckState(
        phase: VendorVersionCheckPhase.failed,
        errorMessage: error.toString(),
      );
      _outputExpanded = true;
      onOutput(
        OutputLine(
          source: OutputSource.system,
          text: 'Vendor version check failed: $error',
          timestamp: DateTime.now(),
        ),
      );
      notifyListeners();
      return null;
    }
  }

  Future<void> runFullInstallation() async {
    if (!canRunOperations) {
      return;
    }
    await _runOperation(
      OperationKind.fullInstall,
      () => _gateway.runFullInstallation(this),
    );
  }

  @override
  void onRootValidated(String rootPath) {
    _rootPath = rootPath;
    _startupPhase = StartupUiPhase.loading;
    notifyListeners();
  }

  @override
  void onOperationRunning({String? logPath}) {
    if (!isOperationActive) {
      return;
    }
    _operation = OperationState(
      kind: _operation.kind,
      phase: OperationPhase.running,
      logPath: logPath ?? _operation.logPath,
    );
    _latestLogPath = logPath ?? _latestLogPath;
    notifyListeners();
  }

  @override
  void onOutput(OutputLine line) {
    _output.add(line);
    if (_output.length > _maximumOutputLines) {
      _output.removeRange(0, _output.length - _maximumOutputLines);
    }
    notifyListeners();
  }

  @override
  void onProgress(ProgressSnapshot snapshot) {
    _progress = snapshot;
    notifyListeners();
  }

  @override
  void onVendorVersionProgress(VendorVersionCheckProgress progress) {
    if (!isVendorVersionCheckActive) {
      return;
    }
    _vendorVersionCheck = VendorVersionCheckState(
      phase: VendorVersionCheckPhase.running,
      completed: progress.completed,
      total: progress.total,
      currentPackage: progress.currentPackage,
    );
    notifyListeners();
  }

  Future<void> _runOperation(
    OperationKind kind,
    Future<OperationResult> Function() action, {
    PackageSpec? target,
  }) async {
    try {
      await _beginOperation(kind, target: target);
      final OperationResult result = await action();
      await _completeOperation(result, kind, target: target);
      await _refreshAfterOperation();
    } on Object catch (error) {
      await _publishLocalFailure(kind, error.toString(), target: target);
      await _refreshAfterOperation();
    }
  }

  Future<void> _beginOperation(
    OperationKind kind, {
    PackageSpec? target,
  }) async {
    _operation = OperationState(kind: kind, phase: OperationPhase.preparing);
    _progress = target == null
        ? null
        : ProgressSnapshot(
            totalTargetSlots: 1,
            currentPackage: target,
            currentStage: BuildStage.preparing,
          );
    notifyListeners();
    // Be pessimistic before crossing the platform channel: the native side
    // may apply the guard even if its acknowledgement is lost.
    _nativeCloseGuardEnabled = true;
    try {
      await _windowCloseGuard.setPreventClose(true);
    } on Object {
      await _disableNativeCloseGuard();
      rethrow;
    }
  }

  Future<void> _completeOperation(
    OperationResult result,
    OperationKind kind, {
    PackageSpec? target,
  }) async {
    _latestLogPath = result.logPath ?? _operation.logPath ?? _latestLogPath;
    _operation = OperationState(
      kind: kind,
      phase: result.succeeded
          ? OperationPhase.succeeded
          : OperationPhase.failed,
      exitCode: result.exitCode,
      logPath: result.logPath ?? _operation.logPath,
      errorMessage: result.errorMessage,
    );
    if (target != null) {
      _progress = _terminalSyntheticProgress(
        target,
        succeeded: result.succeeded,
      );
    }
    if (!result.succeeded) {
      _outputExpanded = true;
    }
    notifyListeners();
    await _disableNativeCloseGuard();
  }

  Future<void> _publishLocalFailure(
    OperationKind kind,
    String message, {
    PackageSpec? target,
  }) async {
    _operation = OperationState(
      kind: kind,
      phase: OperationPhase.failed,
      errorMessage: message,
      logPath: _operation.logPath,
    );
    if (target != null) {
      _progress = _terminalSyntheticProgress(target, succeeded: false);
    }
    _outputExpanded = true;
    onOutput(
      OutputLine(
        source: OutputSource.system,
        text: message,
        timestamp: DateTime.now(),
      ),
    );
    await _disableNativeCloseGuard();
  }

  Future<void> _disableNativeCloseGuard() async {
    if (!_nativeCloseGuardEnabled) {
      return;
    }
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _windowCloseGuard.setPreventClose(false);
        _nativeCloseGuardEnabled = false;
        return;
      } on Object catch (error) {
        lastError = error;
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }
    // Keep the flag set so a later operation/failure path can retry instead
    // of assuming that the native WM_CLOSE guard was released.
    onOutput(
      OutputLine(
        source: OutputSource.system,
        text: 'Could not release the native close guard: $lastError',
        timestamp: DateTime.now(),
      ),
    );
  }

  ProgressSnapshot _terminalSyntheticProgress(
    PackageSpec target, {
    required bool succeeded,
  }) => ProgressSnapshot(
    totalTargetSlots: 1,
    completedTargetSlotIds: succeeded
        ? const <String>{'individual-operation'}
        : const <String>{},
    currentPackage: target,
    currentStage: succeeded ? BuildStage.completed : BuildStage.failed,
    failed: !succeeded,
  );

  PackageSpec _displaySpecification(PackageUiModel package) =>
      PackageSpec(name: package.name, triplet: package.triplet);

  Future<void> _refreshAfterOperation() async {
    try {
      final List<PackageUiModel> refreshed = await _gateway.refreshCatalog(
        this,
      );
      _replacePackages(refreshed);
      notifyListeners();
    } on Object catch (error) {
      onOutput(
        OutputLine(
          source: OutputSource.system,
          text: 'Could not refresh installed state: $error',
          timestamp: DateTime.now(),
        ),
      );
    }
  }

  void _replacePackages(Iterable<PackageUiModel> packages) {
    final String? selectedName = _selectedPackage?.name;
    _packages
      ..clear()
      ..addAll(packages)
      ..sort(
        (PackageUiModel left, PackageUiModel right) =>
            left.name.compareTo(right.name),
      );
    _applyFilter();
    if (selectedName != null) {
      _selectedPackage = null;
      for (final PackageUiModel package in _packages) {
        if (package.name == selectedName) {
          _selectedPackage = package;
          break;
        }
      }
    }
    if (_selectedPackage == null && _packages.isNotEmpty) {
      _selectedPackage = _packages.first;
    }
  }

  void _applyFilter() {
    final RegexFilterResult<PackageUiModel> result = filterByRegex(
      _packages,
      _searchPattern,
      (PackageUiModel package) => package.name,
    );
    _searchError = result.error;
    if (result.isValid) {
      final Iterable<PackageUiModel> visibleItems = _vendorUpdatesOnly
          ? result.items.where(
              (PackageUiModel package) =>
                  vendorVersionFor(package.name)?.hasUpdate ?? false,
            )
          : result.items;
      _filteredPackages
        ..clear()
        ..addAll(visibleItems);
    }
  }
}
