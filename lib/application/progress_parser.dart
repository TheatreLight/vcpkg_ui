import '../domain/package_models.dart';
import '../domain/progress_models.dart';

abstract interface class ProgressParser {
  List<ProgressEvent> parseLine(String line);
}

class WindowsVcpkgProgressParser implements ProgressParser {
  WindowsVcpkgProgressParser(this.plan)
    : _slotsByCategory = _indexSlotsByCategory(plan);

  final FullInstallPlan plan;
  final Map<String, List<TargetSlot>> _slotsByCategory;
  String? _currentCategory;

  static final RegExp _categoryMarker = RegExp(
    r'^\s*CATEGORY:\s*"([^"]+)"',
    caseSensitive: false,
  );
  static final RegExp _libraryMarker = RegExp(
    r'^\s*LIBRARIES:\s*"(.*)"\s*$',
    caseSensitive: false,
  );
  static final RegExp _installingCategory = RegExp(
    r'^\s*Installing category:\s*"([^"]+)"',
    caseSensitive: false,
  );
  static final RegExp _completedCategory = RegExp(
    r'^\s*Successfully installed category:\s*"([^"]+)"',
    caseSensitive: false,
  );
  static final RegExp _retry = RegExp(
    r'^\s*Retry installing\s+"[^"]+"\s*\(Try\s+(\d+)\s+of\s+\d+\)',
    caseSensitive: false,
  );
  static final RegExp _packageSpecification = RegExp(
    r'(?<![A-Za-z0-9+_.-])'
    r'([a-z0-9][a-z0-9+_.-]*(?:\[[^\]\r\n]+\])?:'
    r'[a-z0-9][a-z0-9+_.-]*)',
    caseSensitive: false,
  );

  @override
  List<ProgressEvent> parseLine(String line) {
    final events = <ProgressEvent>[];

    final categoryMatch =
        _categoryMarker.firstMatch(line) ??
        _installingCategory.firstMatch(line);
    if (categoryMatch != null) {
      _currentCategory = categoryMatch.group(1)!.trim();
      events.add(ProgressCategoryChanged(_currentCategory!));
    }

    final librariesMatch = _libraryMarker.firstMatch(line);
    if (librariesMatch != null && _currentCategory != null) {
      final warning = _compareRuntimeCategoryPlan(
        _currentCategory!,
        librariesMatch.group(1)!,
      );
      if (warning != null) {
        events.add(ProgressWarning(warning));
      }
    }

    final retryMatch = _retry.firstMatch(line);
    if (retryMatch != null) {
      events.add(
        ProgressRetryStarted(attempt: int.parse(retryMatch.group(1)!)),
      );
    }

    final completedCategoryMatch = _completedCategory.firstMatch(line);
    if (completedCategoryMatch != null) {
      final category = completedCategoryMatch.group(1)!.trim();
      _currentCategory = category;
      events
        ..add(ProgressCategoryChanged(category))
        ..add(ProgressCategoryCompleted(category));
      return events;
    }

    final specification = _extractSpecification(line);
    if (specification == null) {
      return events;
    }

    final lower = line.toLowerCase();
    final stage = switch (lower) {
      final value when value.contains('downloading') => BuildStage.downloading,
      final value
          when value.contains('restored') ||
              value.contains('restoring') ||
              value.contains('from cache') =>
        BuildStage.restoring,
      final value when value.contains('building') => BuildStage.building,
      final value when value.contains('installing') => BuildStage.installing,
      _ => BuildStage.unknown,
    };
    if (stage != BuildStage.unknown) {
      events.add(
        ProgressPackageChanged(specification: specification, stage: stage),
      );
    }

    if (_isPackageCompletionLine(lower)) {
      final target = _findTarget(specification);
      if (target != null) {
        events.add(ProgressTargetCompleted(target.id));
      }
    }
    return events;
  }

  bool _isPackageCompletionLine(String lower) =>
      lower.contains('already installed') ||
      lower.contains('elapsed time to handle') ||
      lower.contains('successfully installed');

  PackageSpec? _extractSpecification(String line) {
    final match = _packageSpecification.firstMatch(line);
    if (match == null) {
      return null;
    }
    try {
      return PackageSpec.parse(match.group(1)!);
    } on FormatException {
      return null;
    }
  }

  TargetSlot? _findTarget(PackageSpec specification) {
    final candidates = _currentCategory == null
        ? plan.slots
        : (_slotsByCategory[_categoryKey(_currentCategory!)] ?? plan.slots);
    for (final slot in candidates) {
      if (slot.matches(specification)) {
        return slot;
      }
    }
    for (final slot in candidates) {
      if (slot.variants.any(
        (variant) =>
            variant.name == specification.name &&
            variant.triplet == specification.triplet,
      )) {
        return slot;
      }
    }
    return null;
  }

  String? _compareRuntimeCategoryPlan(String category, String rawLibraries) {
    final expected = _slotsByCategory[_categoryKey(category)];
    if (expected == null) {
      return 'Runtime output contains unknown category "$category".';
    }
    final actual = _packageSpecification
        .allMatches(rawLibraries)
        .map((match) {
          try {
            return PackageSpec.parse(match.group(1)!);
          } on FormatException {
            return null;
          }
        })
        .whereType<PackageSpec>()
        .toList(growable: false);

    final missing = expected
        .where(
          (slot) => !actual.any(
            (spec) =>
                slot.matches(spec) ||
                slot.variants.any(
                  (variant) =>
                      variant.name == spec.name &&
                      variant.triplet == spec.triplet,
                ),
          ),
        )
        .map((slot) => slot.variants.first.name)
        .toList(growable: false);
    final unexpected = actual
        .where(
          (spec) => !expected.any(
            (slot) =>
                slot.matches(spec) ||
                slot.variants.any(
                  (variant) =>
                      variant.name == spec.name &&
                      variant.triplet == spec.triplet,
                ),
          ),
        )
        .map((spec) => spec.vcpkgArgument)
        .toList(growable: false);
    if (missing.isEmpty && unexpected.isEmpty) {
      return null;
    }
    return 'Runtime plan mismatch for "$category": '
        'missing [${missing.join(', ')}], '
        'unexpected [${unexpected.join(', ')}].';
  }

  static Map<String, List<TargetSlot>> _indexSlotsByCategory(
    FullInstallPlan plan,
  ) {
    final result = <String, List<TargetSlot>>{};
    for (final slot in plan.slots) {
      result.putIfAbsent(_categoryKey(slot.category), () => []).add(slot);
    }
    return result;
  }

  static String _categoryKey(String value) => value.trim().toLowerCase();
}

class ProgressAccumulator {
  ProgressAccumulator(this.plan)
    : _slotsById = <String, TargetSlot>{
        for (final slot in plan.slots) slot.id: slot,
      },
      snapshot = ProgressSnapshot(totalTargetSlots: plan.totalTargetSlots);

  final FullInstallPlan plan;
  final Map<String, TargetSlot> _slotsById;
  ProgressSnapshot snapshot;

  ProgressSnapshot apply(ProgressEvent event) {
    final completed = snapshot.completedTargetSlotIds.toSet();
    var currentPackage = snapshot.currentPackage;
    var currentStage = snapshot.currentStage;
    var currentCategory = snapshot.currentCategory;
    var retryAttempt = snapshot.retryAttempt;

    switch (event) {
      case ProgressCategoryChanged():
        currentCategory = event.category;
      case ProgressPackageChanged():
        currentPackage = event.specification;
        currentStage = event.stage;
        retryAttempt = null;
      case ProgressTargetCompleted():
        if (_slotsById.containsKey(event.targetSlotId)) {
          completed.add(event.targetSlotId);
        }
      case ProgressCategoryCompleted():
        final categoryKey = event.category.trim().toLowerCase();
        completed.addAll(
          plan.slots
              .where(
                (slot) => slot.category.trim().toLowerCase() == categoryKey,
              )
              .map((slot) => slot.id),
        );
      case ProgressRetryStarted():
        retryAttempt = event.attempt;
        currentPackage = event.specification ?? currentPackage;
        currentStage = BuildStage.retrying;
      case ProgressWarning():
        break;
    }

    snapshot = ProgressSnapshot(
      totalTargetSlots: plan.totalTargetSlots,
      completedTargetSlotIds: completed,
      currentPackage: currentPackage,
      currentStage: currentStage,
      currentCategory: currentCategory,
      retryAttempt: retryAttempt,
    );
    return snapshot;
  }

  ProgressSnapshot finish({required bool succeeded}) {
    snapshot = ProgressSnapshot(
      totalTargetSlots: plan.totalTargetSlots,
      completedTargetSlotIds: succeeded
          ? _slotsById.keys
          : snapshot.completedTargetSlotIds,
      currentPackage: snapshot.currentPackage,
      currentStage: succeeded ? BuildStage.completed : BuildStage.failed,
      currentCategory: snapshot.currentCategory,
      retryAttempt: snapshot.retryAttempt,
      failed: !succeeded,
    );
    return snapshot;
  }
}
