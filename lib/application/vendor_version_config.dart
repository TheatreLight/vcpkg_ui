import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/application/jsonc_parser.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';

final class VendorVersionConfigException implements Exception {
  const VendorVersionConfigException(this.message);

  final String message;

  @override
  String toString() => 'VendorVersionConfigException: $message';
}

final class VersionTextTransform {
  const VersionTextTransform.replace({required this.from, required this.to});

  final String from;
  final String to;

  String apply(String value) => value.replaceAll(from, to);

  String get fingerprint => 'replace:$from:$to';
}

sealed class VendorVersionRule {
  const VendorVersionRule({required this.packageName, this.note});

  final String packageName;
  final String? note;

  String get provider;
  String get fingerprint;
  String? get repository => null;
  Uri? get upstreamUri => null;
  VcpkgVersionScheme? get comparisonScheme => null;
  List<VersionTextTransform> get versionTransforms =>
      const <VersionTextTransform>[];
  List<VersionTextTransform> get localVersionTransforms =>
      const <VersionTextTransform>[];

  String transformVendorVersion(String value) =>
      _applyTransforms(value, versionTransforms);

  String transformLocalVersion(String value) =>
      _applyTransforms(value, localVersionTransforms);

  static String _applyTransforms(
    String value,
    List<VersionTextTransform> transforms,
  ) {
    var result = value;
    for (final VersionTextTransform transform in transforms) {
      result = transform.apply(result);
    }
    return result;
  }
}

final class GithubTagsVendorVersionRule extends VendorVersionRule {
  GithubTagsVendorVersionRule({
    required super.packageName,
    required this.githubRepository,
    required this.tagPrefix,
    required this.tagRegex,
    this.scheme,
    this.vendorTransforms = const <VersionTextTransform>[],
    this.localTransforms = const <VersionTextTransform>[],
    super.note,
  }) : matcher = RegExp(tagRegex);

  final String githubRepository;
  final String tagPrefix;
  final String tagRegex;
  final RegExp matcher;
  final VcpkgVersionScheme? scheme;
  final List<VersionTextTransform> vendorTransforms;
  final List<VersionTextTransform> localTransforms;

  @override
  String get provider => 'github-tags';

  @override
  String get repository => githubRepository;

  @override
  Uri get upstreamUri => Uri.parse('https://github.com/$githubRepository');

  @override
  VcpkgVersionScheme? get comparisonScheme => scheme;

  @override
  List<VersionTextTransform> get versionTransforms => vendorTransforms;

  @override
  List<VersionTextTransform> get localVersionTransforms => localTransforms;

  @override
  String get fingerprint => <String>[
    provider,
    githubRepository.toLowerCase(),
    tagPrefix,
    tagRegex,
    scheme?.name ?? '',
    ...vendorTransforms.map((VersionTextTransform item) => item.fingerprint),
    'local',
    ...localTransforms.map((VersionTextTransform item) => item.fingerprint),
  ].join('|');
}

final class HttpIndexVendorVersionRule extends VendorVersionRule {
  HttpIndexVendorVersionRule({
    required super.packageName,
    required Iterable<Uri> indexUrls,
    required this.entryRegex,
    this.scheme,
    this.vendorTransforms = const <VersionTextTransform>[],
    this.localTransforms = const <VersionTextTransform>[],
    super.note,
  }) : indexUrls = List<Uri>.unmodifiable(indexUrls),
       matcher = RegExp(entryRegex, caseSensitive: false);

  final List<Uri> indexUrls;
  final String entryRegex;
  final RegExp matcher;
  final VcpkgVersionScheme? scheme;
  final List<VersionTextTransform> vendorTransforms;
  final List<VersionTextTransform> localTransforms;

  @override
  String get provider => 'http-index';

  @override
  Uri? get upstreamUri => indexUrls.firstOrNull;

  @override
  VcpkgVersionScheme? get comparisonScheme => scheme;

  @override
  List<VersionTextTransform> get versionTransforms => vendorTransforms;

  @override
  List<VersionTextTransform> get localVersionTransforms => localTransforms;

  @override
  String get fingerprint => <String>[
    provider,
    ...indexUrls.map((Uri item) => item.toString()),
    entryRegex,
    scheme?.name ?? '',
    ...vendorTransforms.map((VersionTextTransform item) => item.fingerprint),
    'local',
    ...localTransforms.map((VersionTextTransform item) => item.fingerprint),
  ].join('|');
}

final class GithubCommitDateVendorVersionRule extends VendorVersionRule {
  const GithubCommitDateVendorVersionRule({
    required super.packageName,
    required this.githubRepository,
    required this.branch,
    required this.localCommit,
    super.note,
  });

  final String githubRepository;
  final String branch;
  final String localCommit;

  @override
  String get provider => 'github-commit-date';

  @override
  String get repository => githubRepository;

  @override
  Uri get upstreamUri => Uri.parse('https://github.com/$githubRepository');

  @override
  VcpkgVersionScheme get comparisonScheme => VcpkgVersionScheme.date;

  @override
  String get fingerprint =>
      '$provider|${githubRepository.toLowerCase()}|$branch|$localCommit';
}

final class DisabledVendorVersionRule extends VendorVersionRule {
  const DisabledVendorVersionRule({
    required super.packageName,
    required this.reason,
  });

  final String reason;

  @override
  String get provider => 'disabled';

  @override
  String get fingerprint => '$provider|$reason';
}

final class InvalidVendorVersionRule extends VendorVersionRule {
  const InvalidVendorVersionRule({
    required super.packageName,
    required this.reason,
  });

  final String reason;

  @override
  String get provider => 'invalid';

  @override
  String get fingerprint => '$provider|$reason';
}

final class VendorVersionConfiguration {
  VendorVersionConfiguration({
    required Map<String, VendorVersionRule> packages,
    required this.filePath,
  }) : packages = UnmodifiableMapView<String, VendorVersionRule>(
         Map<String, VendorVersionRule>.from(packages),
       );

  factory VendorVersionConfiguration.empty(String filePath) =>
      VendorVersionConfiguration(
        packages: const <String, VendorVersionRule>{},
        filePath: filePath,
      );

  final Map<String, VendorVersionRule> packages;
  final String filePath;
}

final class VendorVersionConfigLoader {
  const VendorVersionConfigLoader(this.filePath);

  final String filePath;

  Future<VendorVersionConfiguration> load() async {
    final File file = File(filePath);
    if (!await file.exists()) {
      return VendorVersionConfiguration.empty(filePath);
    }
    final Object? decoded;
    try {
      decoded = decodeJsonc(await file.readAsString());
    } on Object catch (error) {
      throw VendorVersionConfigException('Could not parse $filePath: $error');
    }
    if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) {
      throw VendorVersionConfigException(
        '$filePath must be a JSONC object with schema 1.',
      );
    }
    final Object? rawPackages = decoded['packages'];
    if (rawPackages is! Map<String, dynamic>) {
      throw VendorVersionConfigException(
        '$filePath must contain a packages object.',
      );
    }
    final Map<String, VendorVersionRule> rules = <String, VendorVersionRule>{};
    for (final MapEntry<String, dynamic> entry in rawPackages.entries) {
      final String packageName = entry.key.trim().toLowerCase();
      if (!RegExp(r'^[a-z0-9][a-z0-9+_.-]*$').hasMatch(packageName)) {
        continue;
      }
      try {
        rules[packageName] = _parseRule(packageName, entry.value);
      } on Object catch (error) {
        rules[packageName] = InvalidVendorVersionRule(
          packageName: packageName,
          reason: 'Invalid vendor source rule: $error',
        );
      }
    }
    return VendorVersionConfiguration(packages: rules, filePath: filePath);
  }

  VendorVersionRule _parseRule(String packageName, Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('rule must be a JSON object');
    }
    final String provider = _requiredString(raw, 'provider');
    final String? note = _optionalString(raw, 'note');
    return switch (provider) {
      'github-tags' => _parseGithubTags(packageName, raw, note),
      'http-index' => _parseHttpIndex(packageName, raw, note),
      'github-commit-date' => _parseGithubCommitDate(packageName, raw, note),
      'disabled' => DisabledVendorVersionRule(
        packageName: packageName,
        reason: _requiredString(raw, 'reason'),
      ),
      _ => throw FormatException('unknown provider "$provider"'),
    };
  }

  GithubTagsVendorVersionRule _parseGithubTags(
    String packageName,
    Map<String, dynamic> raw,
    String? note,
  ) {
    final String repository = _repository(raw);
    final String tagRegex = _versionRegex(raw, 'tagRegex');
    return GithubTagsVendorVersionRule(
      packageName: packageName,
      githubRepository: repository,
      tagPrefix: _requiredString(raw, 'tagPrefix', allowEmpty: true),
      tagRegex: tagRegex,
      scheme: _scheme(raw),
      vendorTransforms: _transforms(raw, 'versionTransforms'),
      localTransforms: _transforms(raw, 'localVersionTransforms'),
      note: note,
    );
  }

  HttpIndexVendorVersionRule _parseHttpIndex(
    String packageName,
    Map<String, dynamic> raw,
    String? note,
  ) {
    final Object? values = raw['indexUrls'];
    if (values is! List || values.isEmpty) {
      throw const FormatException('indexUrls must be a non-empty array');
    }
    final List<Uri> urls = <Uri>[];
    for (final Object? value in values) {
      if (value is! String) {
        throw const FormatException('indexUrls values must be strings');
      }
      final Uri? uri = Uri.tryParse(value);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        throw FormatException('index URL must be absolute HTTPS: $value');
      }
      urls.add(uri);
    }
    return HttpIndexVendorVersionRule(
      packageName: packageName,
      indexUrls: urls,
      entryRegex: _versionRegex(raw, 'entryRegex'),
      scheme: _scheme(raw),
      vendorTransforms: _transforms(raw, 'versionTransforms'),
      localTransforms: _transforms(raw, 'localVersionTransforms'),
      note: note,
    );
  }

  GithubCommitDateVendorVersionRule _parseGithubCommitDate(
    String packageName,
    Map<String, dynamic> raw,
    String? note,
  ) {
    final String localCommit = _requiredString(raw, 'localCommit');
    if (!RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(localCommit)) {
      throw const FormatException('localCommit must be a 40-character SHA');
    }
    return GithubCommitDateVendorVersionRule(
      packageName: packageName,
      githubRepository: _repository(raw),
      branch: _requiredString(raw, 'branch'),
      localCommit: localCommit.toLowerCase(),
      note: note,
    );
  }

  String _repository(Map<String, dynamic> raw) {
    final String value = _requiredString(raw, 'repository');
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(value)) {
      throw const FormatException('repository must be owner/name');
    }
    return value;
  }

  String _versionRegex(Map<String, dynamic> raw, String field) {
    final String value = _requiredString(raw, field);
    try {
      RegExp(value);
    } on FormatException catch (error) {
      throw FormatException('$field is invalid: ${error.message}');
    }
    if (!value.contains('(?<version>')) {
      throw FormatException('$field must contain a named version group');
    }
    return value;
  }

  VcpkgVersionScheme? _scheme(Map<String, dynamic> raw) {
    final String? value = _optionalString(raw, 'comparisonScheme');
    if (value == null) {
      return null;
    }
    return VcpkgVersionScheme.values
            .where((VcpkgVersionScheme item) => item.name == value)
            .firstOrNull ??
        (throw FormatException('unknown comparisonScheme "$value"'));
  }

  List<VersionTextTransform> _transforms(
    Map<String, dynamic> raw,
    String field,
  ) {
    final Object? values = raw[field];
    if (values == null) {
      return const <VersionTextTransform>[];
    }
    if (values is! List) {
      throw FormatException('$field must be an array');
    }
    return List<VersionTextTransform>.unmodifiable(
      values.map((Object? value) {
        if (value is! Map<String, dynamic> || value['type'] != 'replace') {
          throw FormatException('$field supports only replace transforms');
        }
        final String from = _requiredString(value, 'from');
        return VersionTextTransform.replace(
          from: from,
          to: _requiredString(value, 'to', allowEmpty: true),
        );
      }),
    );
  }

  String _requiredString(
    Map<String, dynamic> raw,
    String field, {
    bool allowEmpty = false,
  }) {
    final Object? value = raw[field];
    if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
      throw FormatException('$field must be a string');
    }
    return value.trim();
  }

  String? _optionalString(Map<String, dynamic> raw, String field) {
    final Object? value = raw[field];
    if (value == null) {
      return null;
    }
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$field must be a non-empty string');
    }
    return value.trim();
  }

  static String locate({
    Map<String, String> environment = const <String, String>{},
    String? currentDirectory,
    String? executablePath,
  }) {
    final String? explicit = environment['VCPKG_UI_VENDOR_SOURCES']?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return path.normalize(path.absolute(explicit));
    }
    const List<String> relatives = <String>[
      'config/vendor-version-sources.jsonc',
      'config/vendor-version-sources.json',
    ];
    final List<String> roots = <String>[
      currentDirectory ?? Directory.current.path,
      path.dirname(executablePath ?? Platform.resolvedExecutable),
    ];
    for (final String root in roots) {
      var candidateRoot = path.normalize(path.absolute(root));
      for (var depth = 0; depth < 7; depth++) {
        for (final String relative in relatives) {
          final String candidate = path.join(candidateRoot, relative);
          if (File(candidate).existsSync()) {
            return candidate;
          }
        }
        final String parent = path.dirname(candidateRoot);
        if (parent == candidateRoot) {
          break;
        }
        candidateRoot = parent;
      }
    }
    return path.normalize(
      path.absolute(path.join(roots.first, relatives.first)),
    );
  }
}
