import 'dart:collection';

import 'package:vcpkg_ui/domain/package_models.dart';

enum BuildStage {
  preparing,
  downloading,
  restoring,
  building,
  installing,
  retrying,
  completed,
  failed,
  unknown,
}

sealed class ProgressEvent {
  const ProgressEvent();
}

final class ProgressCategoryChanged extends ProgressEvent {
  const ProgressCategoryChanged(this.category);

  final String category;
}

final class ProgressPackageChanged extends ProgressEvent {
  const ProgressPackageChanged({
    required this.specification,
    required this.stage,
  });

  final PackageSpec specification;
  final BuildStage stage;
}

final class ProgressTargetCompleted extends ProgressEvent {
  const ProgressTargetCompleted(this.targetSlotId);

  final String targetSlotId;
}

final class ProgressCategoryCompleted extends ProgressEvent {
  const ProgressCategoryCompleted(this.category);

  final String category;
}

final class ProgressRetryStarted extends ProgressEvent {
  const ProgressRetryStarted({required this.attempt, this.specification});

  final int attempt;
  final PackageSpec? specification;
}

final class ProgressWarning extends ProgressEvent {
  const ProgressWarning(this.message);

  final String message;
}

final class ProgressSnapshot {
  ProgressSnapshot({
    required this.totalTargetSlots,
    Iterable<String> completedTargetSlotIds = const <String>[],
    this.currentPackage,
    this.currentStage = BuildStage.preparing,
    this.currentCategory,
    this.retryAttempt,
    this.failed = false,
  }) : completedTargetSlotIds = UnmodifiableSetView<String>(
         completedTargetSlotIds.toSet(),
       );

  final int totalTargetSlots;
  final Set<String> completedTargetSlotIds;
  final PackageSpec? currentPackage;
  final BuildStage currentStage;
  final String? currentCategory;
  final int? retryAttempt;
  final bool failed;

  int get completedTargetSlots => completedTargetSlotIds.length;

  double get fraction => totalTargetSlots == 0
      ? 0
      : (completedTargetSlots / totalTargetSlots).clamp(0, 1);
}
