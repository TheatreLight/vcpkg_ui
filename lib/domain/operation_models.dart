enum OperationKind {
  catalog,
  packageInfo,
  install,
  removePreview,
  remove,
  removeAll,
  updatePreview,
  updateAll,
  vendorVersionCheck,
  fullInstall,
}

enum OperationPhase { idle, preparing, running, succeeded, failed }

final class OperationState {
  const OperationState({
    this.kind,
    this.phase = OperationPhase.idle,
    this.exitCode,
    this.logPath,
    this.errorMessage,
  });

  final OperationKind? kind;
  final OperationPhase phase;
  final int? exitCode;
  final String? logPath;
  final String? errorMessage;

  bool get isActive =>
      phase == OperationPhase.preparing || phase == OperationPhase.running;

  bool get isTerminal =>
      phase == OperationPhase.succeeded || phase == OperationPhase.failed;
}
