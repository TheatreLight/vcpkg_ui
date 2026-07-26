import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_controller.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_gateway.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';
import 'package:vcpkg_ui/presentation/widgets/catalog_pane.dart';
import 'package:vcpkg_ui/presentation/widgets/library_detail_pane.dart';
import 'package:vcpkg_ui/presentation/widgets/output_panel.dart';
import 'package:vcpkg_ui/presentation/widgets/progress_panel.dart';
import 'package:vcpkg_ui/presentation/widgets/startup_panel.dart';

enum _MaintenanceAction { checkVendorVersions, updateAll, removeAll }

class VcpkgHomeScreen extends StatefulWidget {
  const VcpkgHomeScreen({super.key, required this.controller});

  final VcpkgUiController controller;

  @override
  State<VcpkgHomeScreen> createState() => _VcpkgHomeScreenState();
}

class _VcpkgHomeScreenState extends State<VcpkgHomeScreen> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: _handleExitRequest,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.initialize();
    });
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<AppExitResponse> _handleExitRequest() async {
    if (!widget.controller.isOperationActive) {
      return AppExitResponse.exit;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Wait for the active vcpkg operation to finish before closing.',
          ),
        ),
      );
    }
    return AppExitResponse.cancel;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, Widget? child) {
        final VcpkgUiController controller = widget.controller;
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 20,
            title: Row(
              children: <Widget>[
                const Text('Vcpkg UI'),
                const SizedBox(width: 24),
                Expanded(
                  child: Text(
                    controller.rootPath == null
                        ? 'VCPKG_ROOT: ${controller.environmentRoot ?? 'not set'}'
                        : 'VCPKG_ROOT: ${controller.rootPath}',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: PopupMenuButton<_MaintenanceAction>(
                  enabled: controller.canRunOperations,
                  tooltip: 'Maintenance actions',
                  icon: const Icon(Icons.build_circle_outlined),
                  onSelected: (_MaintenanceAction action) async {
                    switch (action) {
                      case _MaintenanceAction.checkVendorVersions:
                        await _checkVendorVersions(context);
                      case _MaintenanceAction.updateAll:
                        await _previewAndConfirmUpdateAll(context);
                      case _MaintenanceAction.removeAll:
                        await _confirmRemoveAll(context);
                    }
                  },
                  itemBuilder: (BuildContext context) =>
                      const <PopupMenuEntry<_MaintenanceAction>>[
                        PopupMenuItem<_MaintenanceAction>(
                          value: _MaintenanceAction.checkVendorVersions,
                          child: ListTile(
                            leading: Icon(Icons.travel_explore),
                            title: Text('Check vendor versions'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem<_MaintenanceAction>(
                          value: _MaintenanceAction.updateAll,
                          child: ListTile(
                            leading: Icon(Icons.system_update_alt),
                            title: Text('Update all'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem<_MaintenanceAction>(
                          value: _MaintenanceAction.removeAll,
                          child: ListTile(
                            leading: Icon(Icons.delete_sweep_outlined),
                            title: Text('Remove all'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: FilledButton.icon(
                  onPressed: controller.canRunOperations
                      ? () => _confirmFullInstallation(context)
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Full installation'),
                ),
              ),
            ],
          ),
          body: switch (controller.startupPhase) {
            StartupUiPhase.validating => const StartupProgressPanel(
              message: 'Validating VCPKG_ROOT...',
            ),
            StartupUiPhase.loading => const StartupProgressPanel(
              message: 'Loading package catalog...',
            ),
            StartupUiPhase.invalid => StartupDiagnosticPanel(
              rawRoot: controller.environmentRoot,
              reason: controller.startupError ?? 'Unknown validation error.',
            ),
            StartupUiPhase.ready => _buildReadyBody(controller),
          },
        );
      },
    );
  }

  Widget _buildReadyBody(VcpkgUiController controller) {
    return Column(
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  width: 430,
                  child: CatalogPane(controller: controller),
                ),
                const SizedBox(width: 12),
                Expanded(child: LibraryDetailPane(controller: controller)),
              ],
            ),
          ),
        ),
        ProgressPanel(controller: controller),
        OutputPanel(controller: controller),
      ],
    );
  }

  Future<void> _checkVendorVersions(BuildContext context) async {
    final VendorVersionScanResult? result = await widget.controller
        .checkVendorVersions();
    if (result == null || !context.mounted) {
      return;
    }
    final int unresolved =
        result.count(VendorVersionStatus.unsupported) +
        result.count(VendorVersionStatus.checkFailed) +
        result.count(VendorVersionStatus.rateLimited);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Vendor check: '
          '${result.count(VendorVersionStatus.updateAvailable)} update(s), '
          '${result.count(VendorVersionStatus.current)} current, '
          '$unresolved unresolved.',
        ),
      ),
    );
  }

  Future<void> _previewAndConfirmUpdateAll(BuildContext context) async {
    final UpdatePreviewResult? preview = await widget.controller
        .previewUpdates();
    if (preview == null || !context.mounted) {
      return;
    }

    if (!preview.hasUpdates) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('All libraries are up to date'),
          content: SelectableText(preview.summary),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Update ${preview.plannedPackages.length} packages?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'vcpkg will rebuild all packages in this dry-run plan. '
                  'The operation can take a long time.',
                ),
                const SizedBox(height: 16),
                SelectableText(
                  preview.summary,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
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
            child: const Text('Update all'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.updateAll();
    }
  }

  Future<void> _confirmRemoveAll(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Remove all installed libraries?'),
        content: const Text(
          'The existing remove-all script will uninstall every package with '
          'vcpkg remove --recurse. This cannot be undone and the libraries '
          'will need to be rebuilt before they can be used again.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove all'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.removeAllInstalled();
    }
  }

  Future<void> _confirmFullInstallation(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Run full installation?'),
        content: const Text(
          'The existing platform setup script will run unchanged. This can '
          'take a long time.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Run'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.runFullInstallation();
    }
  }
}
