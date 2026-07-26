import 'dart:collection';

import 'package:vcpkg_ui/domain/vendor_version_models.dart';

/// A validated vcpkg package specification.
///
/// The model deliberately keeps shell syntax out of the domain layer. Platform
/// adapters pass [vcpkgArgument] as one typed process argument.
final class PackageSpec {
  PackageSpec({
    required String name,
    Iterable<String> features = const <String>[],
    required String triplet,
  }) : name = _validatePart(name, 'package name'),
       features = UnmodifiableListView<String>(_normaliseFeatures(features)),
       triplet = _validatePart(triplet, 'triplet');

  factory PackageSpec.parse(String value) {
    final Match? match = RegExp(
      r'^([a-z0-9][a-z0-9+_.-]*)(?:\[([^\]]+)\])?:([a-z0-9][a-z0-9+_.-]*)$',
      caseSensitive: false,
    ).firstMatch(value.trim());
    if (match == null) {
      throw FormatException('Invalid vcpkg package specification: $value');
    }

    final String rawFeatures = match.group(2) ?? '';
    return PackageSpec(
      name: match.group(1)!,
      features: rawFeatures.isEmpty ? const <String>[] : rawFeatures.split(','),
      triplet: match.group(3)!,
    );
  }

  final String name;
  final List<String> features;
  final String triplet;

  String get vcpkgArgument {
    final String featureSuffix = features.isEmpty
        ? ''
        : '[${features.join(',')}]';
    return '$name$featureSuffix:$triplet';
  }

  String get canonicalKey => vcpkgArgument.toLowerCase();

  static String _validatePart(String value, String label) {
    final String normalised = value.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9][a-z0-9+_.-]*$').hasMatch(normalised)) {
      throw ArgumentError.value(
        value,
        label,
        'contains unsupported characters',
      );
    }
    return normalised;
  }

  static List<String> _normaliseFeatures(Iterable<String> values) {
    final Set<String> result = <String>{};
    for (final String value in values) {
      result.add(_validatePart(value, 'feature'));
    }
    return result.toList()..sort();
  }

  @override
  bool operator ==(Object other) =>
      other is PackageSpec && other.canonicalKey == canonicalKey;

  @override
  int get hashCode => canonicalKey.hashCode;

  @override
  String toString() => vcpkgArgument;
}

final class PortMetadata {
  const PortMetadata({
    required this.name,
    this.availableVersion,
    this.sourceVersion,
    this.versionScheme,
    this.portVersion = 0,
    this.description,
    required this.manifestPath,
    this.metadataError,
  });

  final String name;
  final String? availableVersion;
  final String? sourceVersion;
  final VcpkgVersionScheme? versionScheme;
  final int portVersion;
  final String? description;
  final String manifestPath;
  final String? metadataError;

  bool get hasMetadataError => metadataError != null;
}

final class InstalledPackage {
  InstalledPackage({
    required this.name,
    required this.triplet,
    required this.version,
    Iterable<String> features = const <String>[],
  }) : features = UnmodifiableListView<String>(
         PackageSpec._normaliseFeatures(features),
       );

  final String name;
  final String triplet;
  final String version;
  final List<String> features;

  String get key => '${name.toLowerCase()}:${triplet.toLowerCase()}';
}

final class PackageViewState {
  PackageViewState({
    required this.metadata,
    Iterable<InstalledPackage> installed = const <InstalledPackage>[],
  }) : installed = UnmodifiableListView<InstalledPackage>(installed);

  final PortMetadata metadata;
  final List<InstalledPackage> installed;

  bool get isInstalled => installed.isNotEmpty;
}

final class TargetSlot {
  TargetSlot({
    required this.id,
    required this.category,
    required Iterable<PackageSpec> variants,
  }) : variants = UnmodifiableListView<PackageSpec>(
         _deduplicateVariants(variants),
       ) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    if (category.trim().isEmpty) {
      throw ArgumentError.value(category, 'category', 'must not be empty');
    }
    if (this.variants.isEmpty) {
      throw ArgumentError.value(variants, 'variants', 'must not be empty');
    }
  }

  final String id;
  final String category;
  final List<PackageSpec> variants;

  bool get isConditional => variants.length > 1;

  bool matches(PackageSpec specification) => variants.contains(specification);

  bool matchesPackageName(String packageName) => variants.any(
    (PackageSpec variant) =>
        variant.name.toLowerCase() == packageName.toLowerCase(),
  );

  static List<PackageSpec> _deduplicateVariants(
    Iterable<PackageSpec> variants,
  ) {
    final Map<String, PackageSpec> result = <String, PackageSpec>{};
    for (final PackageSpec variant in variants) {
      result.putIfAbsent(variant.canonicalKey, () => variant);
    }
    return result.values.toList(growable: false);
  }
}

final class FullInstallPlan {
  FullInstallPlan({
    required Iterable<TargetSlot> slots,
    Iterable<String> warnings = const <String>[],
  }) : slots = UnmodifiableListView<TargetSlot>(slots),
       warnings = UnmodifiableListView<String>(warnings);

  final List<TargetSlot> slots;
  final List<String> warnings;

  int get totalTargetSlots => slots.length;
}
