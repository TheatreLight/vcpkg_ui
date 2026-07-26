import 'package:flutter/material.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_controller.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_gateway.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';

class CatalogPane extends StatelessWidget {
  const CatalogPane({super.key, required this.controller});

  final VcpkgUiController controller;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              onChanged: controller.updateSearch,
              decoration: InputDecoration(
                labelText: 'Search (regex)',
                hintText: r'^boost-|openssl',
                prefixIcon: const Icon(Icons.search),
                errorText: controller.searchError,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _catalogCaption(controller),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Vendor updates'),
                  selected: controller.vendorUpdatesOnly,
                  onSelected: controller.hasVendorVersionResults
                      ? controller.setVendorUpdatesOnly
                      : null,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: controller.packages.isEmpty
                ? const Center(child: Text('No matching ports'))
                : ListView.builder(
                    itemCount: controller.packages.length,
                    itemExtent: 70,
                    itemBuilder: (BuildContext context, int index) {
                      final PackageUiModel package = controller.packages[index];
                      return _PackageRow(
                        package: package,
                        vendorVersion: controller.vendorVersionFor(
                          package.name,
                        ),
                        selected:
                            package.name == controller.selectedPackage?.name,
                        onTap: () => controller.selectPackage(package),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _catalogCaption(VcpkgUiController controller) {
    final VendorVersionCheckState check = controller.vendorVersionCheck;
    if (check.isActive) {
      final String current = check.currentPackage == null
          ? ''
          : ' - ${check.currentPackage}';
      return 'Checking vendor versions: '
          '${check.completed}/${check.total}$current';
    }
    return '${controller.packages.length} ports';
  }
}

class _PackageRow extends StatelessWidget {
  const _PackageRow({
    required this.package,
    required this.vendorVersion,
    required this.selected,
    required this.onTap,
  });

  final PackageUiModel package;
  final VendorVersionInfo? vendorVersion;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool installed = package.package.isInstalled;
    final bool metadataError = package.package.metadata.hasMetadataError;
    final Color statusColor = metadataError
        ? Theme.of(context).colorScheme.error
        : installed
        ? Colors.green.shade700
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Material(
      color: selected
          ? Theme.of(context).colorScheme.secondaryContainer
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      package.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      _versionCaption(package),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 125,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Text(
                      metadataError
                          ? 'Metadata error'
                          : installed
                          ? 'Installed'
                          : 'Missing',
                      style: Theme.of(
                        context,
                      ).textTheme.labelMedium?.copyWith(color: statusColor),
                    ),
                    if (vendorVersion case final VendorVersionInfo vendor)
                      Text(
                        _vendorCaption(vendor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: _vendorColor(context, vendor.status),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _vendorCaption(VendorVersionInfo version) => switch (version.status) {
    VendorVersionStatus.current => 'Vendor: current',
    VendorVersionStatus.updateAvailable =>
      'Vendor: ${version.vendorVersion ?? 'newer'}',
    VendorVersionStatus.unsupported => 'Vendor: unknown',
    VendorVersionStatus.checkFailed => 'Vendor: failed',
    VendorVersionStatus.rateLimited => 'Vendor: rate limit',
  };

  Color _vendorColor(BuildContext context, VendorVersionStatus status) =>
      switch (status) {
        VendorVersionStatus.current => Colors.green.shade700,
        VendorVersionStatus.updateAvailable => Colors.orange.shade800,
        VendorVersionStatus.unsupported => Theme.of(
          context,
        ).colorScheme.onSurfaceVariant,
        VendorVersionStatus.checkFailed ||
        VendorVersionStatus.rateLimited => Theme.of(context).colorScheme.error,
      };

  String _versionCaption(PackageUiModel package) {
    final String available =
        package.package.metadata.availableVersion ?? 'unavailable';
    final String installed = package.package.installed.isEmpty
        ? 'not installed'
        : package.package.installed
              .map((item) => item.version)
              .toSet()
              .join(', ');
    return 'Available $available | Installed $installed';
  }
}
