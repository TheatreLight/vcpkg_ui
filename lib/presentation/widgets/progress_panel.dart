import 'package:flutter/material.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_controller.dart';
import 'package:vcpkg_ui/domain/operation_models.dart';
import 'package:vcpkg_ui/domain/progress_models.dart';

class ProgressPanel extends StatelessWidget {
  const ProgressPanel({super.key, required this.controller});

  final VcpkgUiController controller;

  @override
  Widget build(BuildContext context) {
    final OperationState operation = controller.operation;
    final ProgressSnapshot? progress = controller.progress;
    if (operation.phase == OperationPhase.idle && progress == null) {
      return const SizedBox.shrink();
    }

    final int completed = progress?.completedTargetSlots ?? 0;
    final int total = progress?.totalTargetSlots ?? 0;
    final double? fraction = total == 0 ? null : progress?.fraction;
    final String percentage = fraction == null
        ? '--'
        : '${(fraction * 100).toStringAsFixed(1)}%';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  _operationLabel(operation),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                if (progress != null) Text('$completed / $total  $percentage'),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value:
                  fraction ??
                  switch (operation.phase) {
                    OperationPhase.succeeded => 1,
                    OperationPhase.failed => 0,
                    _ => null,
                  },
              minHeight: 7,
              color: operation.phase == OperationPhase.failed
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 24,
              runSpacing: 6,
              children: <Widget>[
                _StatusValue(
                  label: 'Current',
                  value: progress?.currentPackage?.vcpkgArgument ?? '--',
                ),
                _StatusValue(
                  label: 'Stage',
                  value: _stageLabel(progress?.currentStage, operation),
                ),
                if (progress?.currentCategory != null)
                  _StatusValue(
                    label: 'Category',
                    value: progress!.currentCategory!,
                  ),
                if (progress?.retryAttempt != null)
                  _StatusValue(
                    label: 'Retry',
                    value: progress!.retryAttempt.toString(),
                  ),
              ],
            ),
            if (operation.phase == OperationPhase.failed) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                <String>[
                  if (operation.errorMessage != null) operation.errorMessage!,
                  if (operation.exitCode != null)
                    'Exit code: ${operation.exitCode}',
                  if (operation.logPath != null) 'Log: ${operation.logPath}',
                ].join(' | '),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _operationLabel(OperationState state) {
    final String operation = switch (state.kind) {
      OperationKind.catalog => 'Catalog',
      OperationKind.packageInfo => 'Package info',
      OperationKind.install => 'Install',
      OperationKind.removePreview => 'Remove preview',
      OperationKind.remove => 'Remove',
      OperationKind.removeAll => 'Remove all installed libraries',
      OperationKind.updatePreview => 'Update preview',
      OperationKind.updateAll => 'Update all libraries',
      OperationKind.vendorVersionCheck => 'Vendor version check',
      OperationKind.fullInstall => 'Full installation',
      null => 'Operation',
    };
    final String phase = switch (state.phase) {
      OperationPhase.idle => 'Idle',
      OperationPhase.preparing => 'Preparing',
      OperationPhase.running => 'Running',
      OperationPhase.succeeded => 'Completed',
      OperationPhase.failed => 'Failed',
    };
    return '$operation - $phase';
  }

  String _stageLabel(BuildStage? stage, OperationState operation) {
    if (stage == null) {
      return switch (operation.phase) {
        OperationPhase.preparing => 'Preparing',
        OperationPhase.running => 'Running',
        OperationPhase.succeeded => 'Completed',
        OperationPhase.failed => 'Failed',
        OperationPhase.idle => '--',
      };
    }
    return switch (stage) {
      BuildStage.preparing => 'Preparing',
      BuildStage.downloading => 'Downloading',
      BuildStage.restoring => 'Restoring from cache',
      BuildStage.building => 'Building',
      BuildStage.installing => 'Installing',
      BuildStage.retrying => 'Retrying',
      BuildStage.completed => 'Completed',
      BuildStage.failed => 'Failed',
      BuildStage.unknown => 'Unknown',
    };
  }
}

class _StatusValue extends StatelessWidget {
  const _StatusValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: value),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
