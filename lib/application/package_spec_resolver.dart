import '../domain/package_models.dart';

class UnresolvedConditionalTargetException implements Exception {
  const UnresolvedConditionalTargetException(this.packageName);

  final String packageName;

  @override
  String toString() =>
      'The full-install script selects $packageName conditionally. '
      'Use Full installation so the script can select the correct variant.';
}

class PackageSpecResolver {
  const PackageSpecResolver(this.plan);

  final FullInstallPlan plan;

  PackageSpec forInstall(String packageName, String defaultTriplet) {
    final matchingSlots = plan.slots
        .where((slot) => slot.matchesPackageName(packageName))
        .toList(growable: false);
    if (matchingSlots.isEmpty) {
      return PackageSpec(name: packageName, triplet: defaultTriplet);
    }

    final variants = <String, PackageSpec>{};
    for (final slot in matchingSlots) {
      for (final variant in slot.variants) {
        variants.putIfAbsent(variant.canonicalKey, () => variant);
      }
    }
    if (variants.length != 1) {
      throw UnresolvedConditionalTargetException(packageName);
    }
    return variants.values.single;
  }
}
