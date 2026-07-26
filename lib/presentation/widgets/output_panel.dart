import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_controller.dart';
import 'package:vcpkg_ui/domain/operation_models.dart';
import 'package:vcpkg_ui/domain/output_models.dart';

class OutputPanel extends StatefulWidget {
  const OutputPanel({super.key, required this.controller});

  final VcpkgUiController controller;

  @override
  State<OutputPanel> createState() => _OutputPanelState();
}

class _OutputPanelState extends State<OutputPanel> {
  final ScrollController _scrollController = ScrollController();
  int _lastLineCount = 0;
  bool _wasExpanded = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VcpkgUiController controller = widget.controller;
    final List<OutputLine> output = controller.output;
    if (controller.outputExpanded &&
        (output.length != _lastLineCount || !_wasExpanded)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
    }
    _lastLineCount = output.length;
    _wasExpanded = controller.outputExpanded;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      height: controller.outputExpanded ? 260 : 50,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        children: <Widget>[
          SizedBox(
            height: 49,
            child: Row(
              children: <Widget>[
                const SizedBox(width: 14),
                const Icon(Icons.terminal, size: 20),
                const SizedBox(width: 8),
                Text('Output', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(width: 10),
                Text(
                  '${output.length} lines',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                if (controller.operation.phase == OperationPhase.failed) ...[
                  const SizedBox(width: 16),
                  Flexible(
                    child: Text(
                      _failureCaption(controller),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                TextButton.icon(
                  onPressed: output.isEmpty ? null : () => _copy(output),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                ),
                TextButton.icon(
                  onPressed: output.isEmpty ? null : controller.clearOutput,
                  icon: const Icon(Icons.clear_all, size: 18),
                  label: const Text('Clear view'),
                ),
                TextButton.icon(
                  onPressed: controller.latestLogPath == null
                      ? null
                      : controller.openLogFile,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Open log file'),
                ),
                IconButton(
                  onPressed: controller.toggleOutput,
                  tooltip: controller.outputExpanded ? 'Collapse' : 'Expand',
                  icon: Icon(
                    controller.outputExpanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
          if (controller.outputExpanded) ...<Widget>[
            const Divider(height: 1),
            Expanded(
              child: output.isEmpty
                  ? const Center(child: Text('No process output yet'))
                  : Container(
                      color: const Color(0xff151719),
                      padding: const EdgeInsets.all(10),
                      alignment: Alignment.topLeft,
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        child: SelectableText(
                          _text(output),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.35,
                            color: Color(0xffe8e8e8),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  String _failureCaption(VcpkgUiController controller) {
    final String operation = controller.operation.kind?.name ?? 'operation';
    final String package =
        controller.progress?.currentPackage?.vcpkgArgument ?? 'unknown package';
    final String exitCode = controller.operation.exitCode?.toString() ?? 'n/a';
    return '$operation failed | $package | exit $exitCode';
  }

  String _text(List<OutputLine> lines) =>
      lines.map((OutputLine line) => line.displayText).join('\n');

  Future<void> _copy(List<OutputLine> output) async {
    await Clipboard.setData(ClipboardData(text: _text(output)));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Output copied.')));
    }
  }

  void _scrollToEnd() {
    if (!mounted || !_scrollController.hasClients) {
      return;
    }
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }
}
