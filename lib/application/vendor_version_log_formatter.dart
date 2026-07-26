import 'package:vcpkg_ui/domain/vendor_version_models.dart';

final class VendorVersionLogFormatter {
  const VendorVersionLogFormatter();

  List<String> details(VendorVersionScanResult result) {
    final List<VendorVersionInfo> packages = result.packages.values.toList()
      ..sort(_comparePackages);
    return packages.map(_formatPackage).toList(growable: false);
  }

  String summary(VendorVersionScanResult result) =>
      'Vendor version check completed: '
      '${result.count(VendorVersionStatus.updateAvailable)} update(s), '
      '${result.count(VendorVersionStatus.current)} current, '
      '${result.count(VendorVersionStatus.unsupported)} unsupported, '
      '${result.count(VendorVersionStatus.checkFailed)} failed, '
      '${result.count(VendorVersionStatus.rateLimited)} rate limited.';

  int _comparePackages(VendorVersionInfo left, VendorVersionInfo right) {
    final int statusResult = _priority(
      left.status,
    ).compareTo(_priority(right.status));
    return statusResult != 0
        ? statusResult
        : left.packageName.compareTo(right.packageName);
  }

  int _priority(VendorVersionStatus status) => switch (status) {
    VendorVersionStatus.checkFailed => 0,
    VendorVersionStatus.rateLimited => 1,
    VendorVersionStatus.updateAvailable => 2,
    VendorVersionStatus.unsupported => 3,
    VendorVersionStatus.current => 4,
  };

  String _formatPackage(VendorVersionInfo package) {
    final List<String> fields = <String>[
      '[${_label(package.status)}] ${package.packageName}',
      'local=${package.localVersion ?? '-'}',
      if (package.vendorVersion != null) 'vendor=${package.vendorVersion}',
      if (package.repository != null) 'repository=${package.repository}',
      if (package.upstreamUrl != null) 'upstream=${package.upstreamUrl}',
      if (package.source != null) 'source=${package.source!.name}',
      'rule=${package.ruleOrigin.name}',
      if (package.releaseUrl != null) 'url=${package.releaseUrl}',
      if (package.checkedAt != null)
        'checked=${package.checkedAt!.toUtc().toIso8601String()}',
      if (package.fromCache) 'cached=yes',
      if (package.reason != null) 'reason=${package.reason}',
    ];
    return fields.join(' | ');
  }

  String _label(VendorVersionStatus status) => switch (status) {
    VendorVersionStatus.current => 'CURRENT',
    VendorVersionStatus.updateAvailable => 'UPDATE',
    VendorVersionStatus.unsupported => 'UNSUPPORTED',
    VendorVersionStatus.checkFailed => 'FAILED',
    VendorVersionStatus.rateLimited => 'RATE_LIMITED',
  };
}
