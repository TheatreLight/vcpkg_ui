import 'package:flutter/material.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_controller.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_gateway.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';

class LibraryDetailPane extends StatelessWidget {
  const LibraryDetailPane({super.key, required this.controller});

  final VcpkgUiController controller;

  @override
  Widget build(BuildContext context) {
    final PackageUiModel? selected = controller.selectedPackage;
    return Card(
      child: selected == null
          ? const Center(child: Text('Select a library'))
          : _LibraryDetails(controller: controller, package: selected),
    );
  }
}

class _LibraryDetails extends StatelessWidget {
  const _LibraryDetails({required this.controller, required this.package});

  final VcpkgUiController controller;
  final PackageUiModel package;

  @override
  Widget build(BuildContext context) {
    final PackageViewState state = package.package;
    final PortMetadata metadata = state.metadata;
    final VendorVersionInfo? vendor = controller.vendorVersionFor(package.name);
    final String installedVersions = state.installed.isEmpty
        ? 'Not installed'
        : state.installed
              .map(
                (InstalledPackage item) => '${item.version} (${item.triplet})',
              )
              .join(', ');
    final String installedFeatures = state.installed
        .expand((InstalledPackage item) => item.features)
        .toSet()
        .join(', ');

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(metadata.name, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 20),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _DetailRow(
                    label: 'Local port',
                    value: metadata.availableVersion ?? 'Unavailable',
                  ),
                  _DetailRow(
                    label: 'Vendor',
                    value: _vendorVersionCaption(vendor),
                  ),
                  if (vendor != null)
                    _DetailRow(label: 'Source', value: _sourceCaption(vendor)),
                  if (vendor?.checkedAt case final DateTime checkedAt)
                    _DetailRow(
                      label: 'Checked',
                      value:
                          '${checkedAt.toLocal().toIso8601String()}'
                          '${vendor!.fromCache ? ' (cached)' : ''}',
                    ),
                  if (vendor?.releaseUrl case final Uri releaseUrl)
                    _DetailRow(
                      label: 'Release URL',
                      value: releaseUrl.toString(),
                    ),
                  _DetailRow(label: 'Installed', value: installedVersions),
                  _DetailRow(label: 'Triplet', value: package.triplet),
                  _DetailRow(
                    label: 'Features',
                    value: installedFeatures.isEmpty
                        ? 'Default'
                        : installedFeatures,
                  ),
                  if (metadata.description
                      case final String description) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      'Description',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    SelectableText(description),
                  ],
                  if (metadata.metadataError
                      case final String error) ...<Widget>[
                    const SizedBox(height: 16),
                    _InlineWarning(text: 'Metadata error: $error'),
                  ],
                  if (vendor?.status == VendorVersionStatus.updateAvailable)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: _InlineWarning(
                        text:
                            'A newer vendor version is available. The local '
                            'vcpkg port needs to be updated.',
                      ),
                    ),
                  if (vendor?.reason case final String reason)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: _InlineWarning(
                        text: 'Vendor version was not determined: $reason',
                      ),
                    ),
                  if (package.installBlockedReason case final String reason)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: _InlineWarning(text: reason),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: <Widget>[
              if (!state.isInstalled)
                FilledButton.icon(
                  onPressed:
                      controller.canRunOperations &&
                          package.installBlockedReason == null
                      ? controller.installSelected
                      : null,
                  icon: const Icon(Icons.download),
                  label: const Text('Install'),
                ),
              if (state.isInstalled)
                FilledButton.tonalIcon(
                  onPressed: controller.canRunOperations
                      ? () => _previewAndConfirmRemove(context)
                      : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _vendorVersionCaption(VendorVersionInfo? vendor) {
    if (vendor == null) {
      return 'Not checked';
    }
    return switch (vendor.status) {
      VendorVersionStatus.current =>
        '${vendor.vendorVersion ?? 'Unknown'} (current)',
      VendorVersionStatus.updateAvailable =>
        '${vendor.vendorVersion ?? 'Unknown'} (update available)',
      VendorVersionStatus.unsupported => 'Could not determine automatically',
      VendorVersionStatus.checkFailed => 'Check failed',
      VendorVersionStatus.rateLimited => 'Provider rate limit reached',
    };
  }

  String _sourceCaption(VendorVersionInfo vendor) {
    final String origin = switch (vendor.ruleOrigin) {
      VendorVersionRuleOrigin.automatic => 'Auto',
      VendorVersionRuleOrigin.configuration => 'Config',
    };
    final String provider = switch (vendor.source) {
      VendorVersionSource.githubRelease => 'GitHub release',
      VendorVersionSource.githubTag => 'GitHub tag',
      VendorVersionSource.githubCommit => 'GitHub commit',
      VendorVersionSource.httpIndex => 'HTTP index',
      null => 'Unavailable',
    };
    final String? location = vendor.repository ?? vendor.upstreamUrl?.host;
    return <String>[origin, provider, ?location].join(' · ');
  }

  Future<void> _previewAndConfirmRemove(BuildContext context) async {
    final RemovePreviewResult? preview = await controller
        .previewRemoveSelected();
    if (preview == null || !context.mounted) {
      return;
    }

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Remove ${package.name}?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SelectableText(preview.summary),
                if (preview.requiresRecursiveRemoval) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    'Dependent packages will also be removed:',
                    style: Theme.of(dialogContext).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  ...preview.dependentPackages.map(
                    (String dependent) => Text('- $dependent'),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              preview.requiresRecursiveRemoval
                  ? 'Remove with dependents'
                  : 'Remove',
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.removeSelected(
        recurse: preview.requiresRecursiveRemoval,
      );
    }
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _InlineWarning extends StatelessWidget {
  const _InlineWarning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.warning_amber, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}
