import 'dart:async';

import 'package:vcpkg_ui/application/port_upstream_source_reader.dart';
import 'package:vcpkg_ui/application/vcpkg_version_comparator.dart';
import 'package:vcpkg_ui/application/vendor_version_config.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';
import 'package:vcpkg_ui/infrastructure/vendor/github_vendor_api.dart';
import 'package:vcpkg_ui/infrastructure/vendor/configured_vendor_api.dart';

typedef VendorVersionProgressCallback =
    void Function(VendorVersionCheckProgress progress);

final class VendorVersionService {
  const VendorVersionService({
    required this.sourceReader,
    required this.githubClient,
    this.configurationLoader,
    this.configuredClient,
    this.comparator = const VcpkgVersionComparator(),
    this.maximumConcurrency = 4,
  }) : assert(maximumConcurrency > 0);

  final PortUpstreamSourceReader sourceReader;
  final GithubVersionClient githubClient;
  final VendorVersionConfigLoader? configurationLoader;
  final ConfiguredVendorVersionClient? configuredClient;
  final VcpkgVersionComparator comparator;
  final int maximumConcurrency;

  Future<VendorVersionScanResult> check({
    required FullInstallPlan plan,
    required Iterable<PackageViewState> catalog,
    VendorVersionProgressCallback? onProgress,
  }) async {
    final VendorVersionConfiguration configuration =
        await configurationLoader?.load() ??
        VendorVersionConfiguration.empty('');
    final Set<String> targetNames = plan.slots
        .expand((TargetSlot slot) => slot.variants)
        .map((PackageSpec specification) => specification.name)
        .toSet();
    final List<String> sortedTargets = targetNames.toList()..sort();
    final Map<String, PackageViewState> catalogByName =
        <String, PackageViewState>{
          for (final PackageViewState package in catalog)
            package.metadata.name.toLowerCase(): package,
        };
    final Map<String, VendorVersionInfo> results =
        <String, VendorVersionInfo>{};
    final Map<String, Future<GithubVersionCandidate>> pendingLookups =
        <String, Future<GithubVersionCandidate>>{};
    final Map<String, Future<ConfiguredVendorVersionCandidate>>
    pendingConfiguredLookups =
        <String, Future<ConfiguredVendorVersionCandidate>>{};
    var nextIndex = 0;
    var completed = 0;
    onProgress?.call(
      VendorVersionCheckProgress(completed: 0, total: sortedTargets.length),
    );

    Future<void> worker() async {
      while (true) {
        final int index = nextIndex++;
        if (index >= sortedTargets.length) {
          return;
        }
        final String packageName = sortedTargets[index];
        final PackageViewState? package = catalogByName[packageName];
        results[packageName] = await _checkPackage(
          packageName,
          package,
          pendingLookups,
          pendingConfiguredLookups,
          configuration,
        );
        completed++;
        onProgress?.call(
          VendorVersionCheckProgress(
            completed: completed,
            total: sortedTargets.length,
            currentPackage: packageName,
          ),
        );
      }
    }

    final int workerCount = sortedTargets.length < maximumConcurrency
        ? sortedTargets.length
        : maximumConcurrency;
    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );
    return VendorVersionScanResult(packages: results);
  }

  Future<VendorVersionInfo> _checkPackage(
    String packageName,
    PackageViewState? package,
    Map<String, Future<GithubVersionCandidate>> pendingLookups,
    Map<String, Future<ConfiguredVendorVersionCandidate>>
    pendingConfiguredLookups,
    VendorVersionConfiguration configuration,
  ) async {
    final PortMetadata? metadata = package?.metadata;
    final String? localVersion = metadata?.sourceVersion;
    final VcpkgVersionScheme? scheme = metadata?.versionScheme;
    if (metadata == null) {
      return _unsupported(
        packageName,
        null,
        'Port is missing from the catalog.',
      );
    }
    if (metadata.hasMetadataError) {
      return _unsupported(
        packageName,
        localVersion,
        'Port metadata is invalid: ${metadata.metadataError}',
      );
    }
    if (localVersion == null || scheme == null) {
      return _unsupported(
        packageName,
        localVersion,
        'The port manifest does not declare a supported version field.',
      );
    }

    final VendorVersionRule? configuredRule =
        configuration.packages[packageName];
    if (configuredRule case DisabledVendorVersionRule()) {
      return VendorVersionInfo(
        packageName: packageName,
        status: VendorVersionStatus.unsupported,
        localVersion: localVersion,
        reason: configuredRule.reason,
        ruleOrigin: VendorVersionRuleOrigin.configuration,
      );
    }
    if (configuredRule case InvalidVendorVersionRule()) {
      return VendorVersionInfo(
        packageName: packageName,
        status: VendorVersionStatus.unsupported,
        localVersion: localVersion,
        reason: configuredRule.reason,
        ruleOrigin: VendorVersionRuleOrigin.configuration,
      );
    }
    if (configuredRule != null) {
      return _checkConfiguredPackage(
        packageName: packageName,
        localVersion: localVersion,
        fallbackScheme: scheme,
        rule: configuredRule,
        origin: VendorVersionRuleOrigin.configuration,
        pendingLookups: pendingConfiguredLookups,
      );
    }

    final PortUpstreamSourceResult discovery = await sourceReader.read(
      metadata,
    );
    if (discovery.httpIndexSource case final HttpIndexPortSource indexSource) {
      return _checkConfiguredPackage(
        packageName: packageName,
        localVersion: localVersion,
        fallbackScheme: scheme,
        rule: HttpIndexVendorVersionRule(
          packageName: packageName,
          indexUrls: indexSource.indexUrls,
          entryRegex: indexSource.entryRegex,
        ),
        origin: VendorVersionRuleOrigin.automatic,
        pendingLookups: pendingConfiguredLookups,
      );
    }
    final GithubPortSource? source = discovery.source;
    if (source == null) {
      return _unsupported(packageName, localVersion, discovery.reason!);
    }
    final String lookupKey = <String>[
      source.repository,
      source.tagPrefix,
      source.tagSuffix,
      scheme.name,
    ].join('|');
    try {
      final GithubVersionCandidate candidate = await pendingLookups.putIfAbsent(
        lookupKey,
        () => githubClient.findLatest(source, scheme),
      );
      final int? comparison = comparator.compare(
        localVersion,
        candidate.version,
        scheme,
      );
      if (comparison == null) {
        return VendorVersionInfo(
          packageName: packageName,
          status: VendorVersionStatus.unsupported,
          localVersion: localVersion,
          vendorVersion: candidate.version,
          repository: source.repository,
          source: candidate.source,
          releaseUrl: candidate.url,
          checkedAt: candidate.checkedAt,
          reason: 'The ${scheme.name} versions cannot be ordered safely.',
          fromCache: candidate.fromCache,
        );
      }
      return VendorVersionInfo(
        packageName: packageName,
        status: comparison < 0
            ? VendorVersionStatus.updateAvailable
            : VendorVersionStatus.current,
        localVersion: localVersion,
        vendorVersion: candidate.version,
        repository: source.repository,
        source: candidate.source,
        releaseUrl: candidate.url,
        checkedAt: candidate.checkedAt,
        fromCache: candidate.fromCache,
      );
    } on GithubVersionNotFoundException catch (error) {
      return VendorVersionInfo(
        packageName: packageName,
        status: VendorVersionStatus.unsupported,
        localVersion: localVersion,
        repository: source.repository,
        reason: error.message,
      );
    } on GithubRateLimitException catch (error) {
      return VendorVersionInfo(
        packageName: packageName,
        status: VendorVersionStatus.rateLimited,
        localVersion: localVersion,
        repository: source.repository,
        reason: error.message,
      );
    } on Object catch (error) {
      return VendorVersionInfo(
        packageName: packageName,
        status: VendorVersionStatus.checkFailed,
        localVersion: localVersion,
        repository: source.repository,
        reason: error.toString(),
      );
    }
  }

  Future<VendorVersionInfo> _checkConfiguredPackage({
    required String packageName,
    required String localVersion,
    required VcpkgVersionScheme fallbackScheme,
    required VendorVersionRule rule,
    required VendorVersionRuleOrigin origin,
    required Map<String, Future<ConfiguredVendorVersionCandidate>>
    pendingLookups,
  }) async {
    final ConfiguredVendorVersionClient? client = configuredClient;
    if (client == null) {
      return VendorVersionInfo(
        packageName: packageName,
        status: VendorVersionStatus.checkFailed,
        localVersion: localVersion,
        repository: rule.repository,
        upstreamUrl: rule.upstreamUri,
        ruleOrigin: origin,
        reason: 'Configured vendor providers have not been initialized.',
      );
    }
    final VcpkgVersionScheme scheme = rule.comparisonScheme ?? fallbackScheme;
    final String lookupKey = '${rule.fingerprint}|${scheme.name}';
    try {
      final ConfiguredVendorVersionCandidate candidate = await pendingLookups
          .putIfAbsent(
            lookupKey,
            () => client.findLatest(rule, fallbackScheme),
          );
      final String comparisonLocal =
          candidate.comparisonLocalVersion ??
          rule.transformLocalVersion(localVersion);
      final int? comparison = comparator.compare(
        comparisonLocal,
        candidate.version,
        scheme,
      );
      if (comparison == null) {
        return VendorVersionInfo(
          packageName: packageName,
          status: VendorVersionStatus.unsupported,
          localVersion: localVersion,
          vendorVersion: candidate.version,
          repository: rule.repository,
          upstreamUrl: rule.upstreamUri,
          source: candidate.source,
          ruleOrigin: origin,
          releaseUrl: candidate.url,
          checkedAt: candidate.checkedAt,
          reason:
              'The ${scheme.name} versions cannot be ordered safely '
              '(local comparison value: $comparisonLocal).',
          fromCache: candidate.fromCache,
        );
      }
      return VendorVersionInfo(
        packageName: packageName,
        status: comparison < 0
            ? VendorVersionStatus.updateAvailable
            : VendorVersionStatus.current,
        localVersion: localVersion,
        vendorVersion: candidate.version,
        repository: rule.repository,
        upstreamUrl: rule.upstreamUri,
        source: candidate.source,
        ruleOrigin: origin,
        releaseUrl: candidate.url,
        checkedAt: candidate.checkedAt,
        fromCache: candidate.fromCache,
      );
    } on ConfiguredVendorVersionNotFoundException catch (error) {
      return VendorVersionInfo(
        packageName: packageName,
        status: VendorVersionStatus.unsupported,
        localVersion: localVersion,
        repository: rule.repository,
        upstreamUrl: rule.upstreamUri,
        ruleOrigin: origin,
        reason: error.message,
      );
    } on ConfiguredVendorRateLimitException catch (error) {
      return VendorVersionInfo(
        packageName: packageName,
        status: VendorVersionStatus.rateLimited,
        localVersion: localVersion,
        repository: rule.repository,
        upstreamUrl: rule.upstreamUri,
        ruleOrigin: origin,
        reason: error.message,
      );
    } on Object catch (error) {
      return VendorVersionInfo(
        packageName: packageName,
        status: VendorVersionStatus.checkFailed,
        localVersion: localVersion,
        repository: rule.repository,
        upstreamUrl: rule.upstreamUri,
        ruleOrigin: origin,
        reason: error.toString(),
      );
    }
  }

  VendorVersionInfo _unsupported(
    String packageName,
    String? localVersion,
    String reason,
  ) => VendorVersionInfo(
    packageName: packageName,
    status: VendorVersionStatus.unsupported,
    localVersion: localVersion,
    reason: reason,
  );
}
