import 'dart:collection';

enum VcpkgVersionScheme { relaxed, semver, date, string }

enum VendorVersionStatus {
  current,
  updateAvailable,
  unsupported,
  checkFailed,
  rateLimited,
}

enum VendorVersionSource { githubRelease, githubTag, githubCommit, httpIndex }

enum VendorVersionRuleOrigin { automatic, configuration }

final class VendorVersionInfo {
  const VendorVersionInfo({
    required this.packageName,
    required this.status,
    required this.localVersion,
    this.vendorVersion,
    this.repository,
    this.upstreamUrl,
    this.source,
    this.ruleOrigin = VendorVersionRuleOrigin.automatic,
    this.releaseUrl,
    this.checkedAt,
    this.reason,
    this.fromCache = false,
  });

  final String packageName;
  final VendorVersionStatus status;
  final String? localVersion;
  final String? vendorVersion;
  final String? repository;
  final Uri? upstreamUrl;
  final VendorVersionSource? source;
  final VendorVersionRuleOrigin ruleOrigin;
  final Uri? releaseUrl;
  final DateTime? checkedAt;
  final String? reason;
  final bool fromCache;

  bool get hasUpdate => status == VendorVersionStatus.updateAvailable;
}

final class VendorVersionCheckProgress {
  const VendorVersionCheckProgress({
    required this.completed,
    required this.total,
    this.currentPackage,
  });

  final int completed;
  final int total;
  final String? currentPackage;
}

final class VendorVersionScanResult {
  VendorVersionScanResult({
    required Map<String, VendorVersionInfo> packages,
    this.logPath,
  }) : packages = UnmodifiableMapView<String, VendorVersionInfo>(
         Map<String, VendorVersionInfo>.from(packages),
       );

  final Map<String, VendorVersionInfo> packages;
  final String? logPath;

  int get checkedCount => packages.length;

  int count(VendorVersionStatus status) =>
      packages.values.where((item) => item.status == status).length;
}

enum VendorVersionCheckPhase { idle, running, completed, failed }

final class VendorVersionCheckState {
  const VendorVersionCheckState({
    this.phase = VendorVersionCheckPhase.idle,
    this.completed = 0,
    this.total = 0,
    this.currentPackage,
    this.errorMessage,
  });

  final VendorVersionCheckPhase phase;
  final int completed;
  final int total;
  final String? currentPackage;
  final String? errorMessage;

  bool get isActive => phase == VendorVersionCheckPhase.running;
}
