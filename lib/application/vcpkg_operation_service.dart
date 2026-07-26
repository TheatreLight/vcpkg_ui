import '../domain/operation_models.dart';
import '../domain/output_models.dart';
import '../domain/package_models.dart';
import '../domain/progress_models.dart';
import '../infrastructure/logging/log_store.dart';
import '../infrastructure/platform/vcpkg_platform_adapter.dart';
import '../infrastructure/process/process_command.dart';
import '../infrastructure/process/process_runner.dart';
import 'full_install_plan_reader.dart';
import 'progress_parser.dart';

typedef OperationStateCallback = void Function(OperationState state);
typedef ProgressSnapshotCallback = void Function(ProgressSnapshot snapshot);
typedef CatalogRefreshCallback = Future<void> Function();
typedef ProgressParserFactory = ProgressParser Function(FullInstallPlan plan);

class OperationInProgressException implements Exception {
  const OperationInProgressException();

  @override
  String toString() => 'Another vcpkg operation is already active.';
}

class OperationCoordinator {
  OperationCoordinator({this.onStateChanged});

  final OperationStateCallback? onStateChanged;
  OperationState _state = const OperationState();

  OperationState get state => _state;
  bool get isActive => _state.isActive;

  void begin(OperationKind kind) {
    if (isActive) {
      throw const OperationInProgressException();
    }
    _publish(OperationState(kind: kind, phase: OperationPhase.preparing));
  }

  void running(OperationKind kind, String logPath) {
    _publish(
      OperationState(
        kind: kind,
        phase: OperationPhase.running,
        logPath: logPath,
      ),
    );
  }

  void succeeded(OperationKind kind, ProcessRunResult result) {
    _publish(
      OperationState(
        kind: kind,
        phase: OperationPhase.succeeded,
        exitCode: result.exitCode,
        logPath: result.logPath,
      ),
    );
  }

  void failed(
    OperationKind kind, {
    ProcessRunResult? result,
    required String message,
  }) {
    _publish(
      OperationState(
        kind: kind,
        phase: OperationPhase.failed,
        exitCode: result?.exitCode,
        logPath: result?.logPath,
        errorMessage: message,
      ),
    );
  }

  void _publish(OperationState state) {
    _state = state;
    onStateChanged?.call(state);
  }
}

final class RemovePreview {
  const RemovePreview({
    required this.specification,
    required this.affectedPackages,
    required this.processResult,
  });

  final PackageSpec specification;
  final List<PackageSpec> affectedPackages;
  final ProcessRunResult processResult;

  bool get requiresRecurse => affectedPackages.any(
    (item) => item.canonicalKey != specification.canonicalKey,
  );
}

final class UpdatePreview {
  const UpdatePreview({
    required this.plannedPackages,
    required this.processResult,
  });

  final List<String> plannedPackages;
  final ProcessRunResult processResult;

  bool get hasUpdates => plannedPackages.isNotEmpty;
}

final class FullInstallExecution {
  const FullInstallExecution({
    required this.plan,
    required this.result,
    required this.progress,
    required this.warnings,
  });

  final FullInstallPlan plan;
  final ProcessRunResult result;
  final ProgressSnapshot progress;
  final List<String> warnings;
}

class VcpkgOperationService {
  const VcpkgOperationService({
    required this.adapter,
    required this.layout,
    required this.runner,
    required this.logStore,
    required this.planReader,
    required this.progressParserFactory,
    required this.coordinator,
    this.onOutput,
    this.onProgress,
    this.refreshCatalog,
  });

  final VcpkgPlatformAdapter adapter;
  final VcpkgLayout layout;
  final ProcessRunner runner;
  final LogStore logStore;
  final FullInstallPlanReader planReader;
  final ProgressParserFactory progressParserFactory;
  final OperationCoordinator coordinator;
  final OutputLineCallback? onOutput;
  final ProgressSnapshotCallback? onProgress;
  final CatalogRefreshCallback? refreshCatalog;

  Future<ProcessRunResult> install(PackageSpec specification) async {
    const kind = OperationKind.install;
    coordinator.begin(kind);
    try {
      final result = await _runLogged(
        kind,
        adapter.installCommand(layout, specification),
      );
      await _finishMutation(kind, result);
      return result;
    } on Object catch (error) {
      if (coordinator.isActive) {
        coordinator.failed(kind, message: error.toString());
      }
      rethrow;
    }
  }

  Future<RemovePreview> previewRemove(PackageSpec specification) async {
    const kind = OperationKind.removePreview;
    coordinator.begin(kind);
    try {
      final result = await _runLogged(
        kind,
        adapter.removePreviewCommand(layout, specification),
        captureOutput: true,
      );
      final previewOutput =
          '${result.capturedStdout}\n${result.capturedStderr}';
      final affected = _parseRemovalPlan(previewOutput);
      final containsRequestedPackage = affected.any(
        (item) => item.canonicalKey == specification.canonicalKey,
      );
      final hasDependentPackages = affected.any(
        (item) => item.canonicalKey != specification.canonicalKey,
      );
      final hasExpectedExitCode =
          result.exitCode == 0 ||
          (result.exitCode == 1 && hasDependentPackages);
      // This vcpkg fork intentionally returns 1 for a valid dry-run when
      // dependants require --recurse. Validate the structured preview instead
      // of treating that documented safety signal as a process failure.
      if (!result.started ||
          result.errorMessage != null ||
          !hasExpectedExitCode ||
          !containsRequestedPackage) {
        final message =
            result.errorMessage ??
            'vcpkg remove --dry-run did not return a removal plan.';
        coordinator.failed(kind, result: result, message: message);
        throw StateError(message);
      }
      coordinator.succeeded(kind, result);
      return RemovePreview(
        specification: specification,
        affectedPackages: List<PackageSpec>.unmodifiable(affected),
        processResult: result,
      );
    } on Object catch (error) {
      if (coordinator.isActive) {
        coordinator.failed(kind, message: error.toString());
      }
      rethrow;
    }
  }

  Future<ProcessRunResult> remove(
    RemovePreview preview, {
    required bool confirmedRecursiveRemoval,
  }) async {
    if (preview.requiresRecurse && !confirmedRecursiveRemoval) {
      throw StateError(
        'Dependent packages require explicit recursive removal confirmation.',
      );
    }

    const kind = OperationKind.remove;
    coordinator.begin(kind);
    try {
      final result = await _runLogged(
        kind,
        adapter.removeCommand(
          layout,
          preview.specification,
          recurse: preview.requiresRecurse,
        ),
      );
      await _finishMutation(kind, result);
      return result;
    } on Object catch (error) {
      if (coordinator.isActive) {
        coordinator.failed(kind, message: error.toString());
      }
      rethrow;
    }
  }

  Future<ProcessRunResult> removeAll() async {
    const kind = OperationKind.removeAll;
    coordinator.begin(kind);
    try {
      final result = await _runLogged(kind, adapter.removeAllCommand(layout));
      await _finishMutation(kind, result);
      return result;
    } on Object catch (error) {
      if (coordinator.isActive) {
        coordinator.failed(kind, message: error.toString());
      }
      rethrow;
    }
  }

  Future<UpdatePreview> previewUpdates() async {
    const kind = OperationKind.updatePreview;
    coordinator.begin(kind);
    try {
      final result = await _runLogged(
        kind,
        adapter.upgradePreviewCommand(layout),
        captureOutput: true,
      );
      final String previewOutput =
          '${result.capturedStdout}\n${result.capturedStderr}';
      final List<String> plannedPackages = _parseUpgradePlan(previewOutput);
      final bool hasExpectedExitCode =
          result.exitCode == 0 ||
          (result.exitCode == 1 && plannedPackages.isNotEmpty);
      // This vcpkg fork returns 1 for a successful upgrade dry-run when
      // packages need rebuilding. A non-empty structured plan distinguishes
      // that safety signal from an actual process failure.
      if (!result.started ||
          result.errorMessage != null ||
          !hasExpectedExitCode) {
        final String message =
            result.errorMessage ??
            'vcpkg upgrade dry-run did not return a valid update plan.';
        coordinator.failed(kind, result: result, message: message);
        throw StateError(message);
      }
      coordinator.succeeded(kind, result);
      return UpdatePreview(
        plannedPackages: List<String>.unmodifiable(plannedPackages),
        processResult: result,
      );
    } on Object catch (error) {
      if (coordinator.isActive) {
        coordinator.failed(kind, message: error.toString());
      }
      rethrow;
    }
  }

  Future<ProcessRunResult> updateAll(UpdatePreview preview) async {
    if (!preview.hasUpdates) {
      throw StateError('No outdated packages were found by the dry-run.');
    }

    const kind = OperationKind.updateAll;
    coordinator.begin(kind);
    try {
      final result = await _runLogged(kind, adapter.upgradeAllCommand(layout));
      await _finishMutation(kind, result);
      return result;
    } on Object catch (error) {
      if (coordinator.isActive) {
        coordinator.failed(kind, message: error.toString());
      }
      rethrow;
    }
  }

  Future<FullInstallExecution> fullInstall() async {
    const kind = OperationKind.fullInstall;
    coordinator.begin(kind);
    try {
      final plan = await planReader.read(layout.fullInstallScriptPath);
      final parser = progressParserFactory(plan);
      final accumulator = ProgressAccumulator(plan);
      final warnings = <String>[...plan.warnings];
      onProgress?.call(accumulator.snapshot);

      final log = await logStore.create(kind);
      coordinator.running(kind, log.path);
      for (final warning in plan.warnings) {
        _emitSystemLine(log, warning);
      }

      final result = await runner.run(
        adapter.fullInstallCommand(layout),
        log: log,
        onOutput: (line) {
          onOutput?.call(line);
          for (final event in parser.parseLine(line.text)) {
            if (event case ProgressWarning(:final message)) {
              warnings.add(message);
              _emitSystemLine(log, message);
            }
            onProgress?.call(accumulator.apply(event));
          }
        },
      );
      final finalProgress = accumulator.finish(succeeded: result.succeeded);
      onProgress?.call(finalProgress);
      if (result.succeeded) {
        coordinator.succeeded(kind, result);
        await _refreshCatalogAfterSuccess();
      } else {
        coordinator.failed(
          kind,
          result: result,
          message: _failureMessage(result),
        );
      }
      return FullInstallExecution(
        plan: plan,
        result: result,
        progress: finalProgress,
        warnings: List<String>.unmodifiable(warnings),
      );
    } on Object catch (error) {
      if (coordinator.isActive) {
        coordinator.failed(kind, message: error.toString());
      }
      rethrow;
    }
  }

  Future<ProcessRunResult> _runLogged(
    OperationKind kind,
    ProcessCommand command, {
    bool captureOutput = false,
  }) async {
    final log = await logStore.create(kind);
    coordinator.running(kind, log.path);
    return runner.run(
      command,
      log: log,
      onOutput: onOutput,
      captureOutput: captureOutput,
    );
  }

  Future<void> _finishMutation(
    OperationKind kind,
    ProcessRunResult result,
  ) async {
    if (result.succeeded) {
      coordinator.succeeded(kind, result);
      await _refreshCatalogAfterSuccess();
    } else {
      coordinator.failed(
        kind,
        result: result,
        message: _failureMessage(result),
      );
    }
  }

  List<PackageSpec> _parseRemovalPlan(String output) {
    const removalHeader = 'the following packages will be removed:';
    final lines = output
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final headerIndex = lines.indexWhere(
      (line) => line.trim().toLowerCase() == removalHeader,
    );
    if (headerIndex < 0) {
      return const <PackageSpec>[];
    }

    final packageLinePattern = RegExp(
      r'^\s*(?:\*\s*)?'
      r'([a-z0-9][a-z0-9+_.-]*(?:\[[^\]]+\])?:'
      r'[a-z0-9][a-z0-9+_.-]*)\s*$',
      caseSensitive: false,
    );
    final result = <String, PackageSpec>{};
    for (var index = headerIndex + 1; index < lines.length; index++) {
      final match = packageLinePattern.firstMatch(lines[index]);
      if (match == null) {
        break;
      }
      try {
        final specification = PackageSpec.parse(match.group(1)!);
        result.putIfAbsent(specification.canonicalKey, () => specification);
      } on FormatException {
        // Preserve the raw line in Output, but ignore malformed preview items.
      }
    }
    return result.values.toList(growable: false);
  }

  List<String> _parseUpgradePlan(String output) {
    const String planHeader = 'the following packages will be rebuilt:';
    final List<String> lines = output
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final int headerIndex = lines.indexWhere(
      (String line) => line.trim().toLowerCase() == planHeader,
    );
    if (headerIndex < 0) {
      return const <String>[];
    }

    final RegExp packageLinePattern = RegExp(r'^\s*\*\s+(.+?)\s*$');
    final List<String> result = <String>[];
    for (var index = headerIndex + 1; index < lines.length; index++) {
      final Match? match = packageLinePattern.firstMatch(lines[index]);
      if (match == null) {
        break;
      }
      result.add(match.group(1)!);
    }
    return result;
  }

  Future<void> _refreshCatalogAfterSuccess() async {
    final refresh = refreshCatalog;
    if (refresh == null) {
      return;
    }
    try {
      await refresh();
    } on Object catch (error) {
      try {
        onOutput?.call(
          OutputLine(
            source: OutputSource.system,
            text:
                'Operation succeeded, but the catalog could not be refreshed: '
                '$error',
            timestamp: DateTime.now(),
          ),
        );
      } on Object {
        // A presentation callback must not turn an already successful vcpkg
        // process into a failed operation.
      }
    }
  }

  void _emitSystemLine(OperationLog log, String message) {
    final line = OutputLine(
      source: OutputSource.system,
      text: message,
      timestamp: DateTime.now(),
    );
    log.write(line);
    onOutput?.call(line);
  }

  String _failureMessage(ProcessRunResult result) =>
      result.errorMessage ??
      (result.started
          ? 'Process exited with code ${result.exitCode}.'
          : 'Process could not be started.');
}
