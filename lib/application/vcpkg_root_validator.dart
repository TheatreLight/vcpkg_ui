import 'package:vcpkg_ui/application/vcpkg_ui_config.dart';

import '../infrastructure/platform/vcpkg_platform_adapter.dart';

sealed class VcpkgRootValidationResult {
  const VcpkgRootValidationResult({required this.rawRoot});

  final String? rawRoot;
}

final class ValidVcpkgRoot extends VcpkgRootValidationResult {
  const ValidVcpkgRoot({required super.rawRoot, required this.layout});

  final VcpkgLayout layout;
}

final class InvalidVcpkgRoot extends VcpkgRootValidationResult {
  const InvalidVcpkgRoot({required super.rawRoot, required this.issues});

  final List<ValidationIssue> issues;

  String get message => issues.map((issue) => issue.message).join('\n');
}

class VcpkgRootValidator {
  const VcpkgRootValidator(this.adapter);

  final VcpkgPlatformAdapter adapter;

  VcpkgRootValidationResult validate(String? rawRoot) {
    if (rawRoot == null || rawRoot.trim().isEmpty) {
      return InvalidVcpkgRoot(
        rawRoot: rawRoot,
        issues: const [
          ValidationIssue(
            code: 'vcpkg_root_missing',
            message:
                'VCPKG_ROOT is not set. Set it and restart the application.',
          ),
        ],
      );
    }

    final VcpkgLayout layout;
    try {
      layout = adapter.createLayout(rawRoot);
    } on VcpkgUiConfigException catch (error) {
      return InvalidVcpkgRoot(
        rawRoot: rawRoot,
        issues: <ValidationIssue>[
          ValidationIssue(
            code: 'application_config_invalid',
            message: error.message,
          ),
        ],
      );
    } on Object catch (error) {
      return InvalidVcpkgRoot(
        rawRoot: rawRoot,
        issues: [
          ValidationIssue(
            code: 'vcpkg_root_invalid',
            message: 'VCPKG_ROOT is invalid: $error',
            path: rawRoot,
          ),
        ],
      );
    }

    final issues = adapter.validateLayout(layout);
    if (issues.any((issue) => issue.isFatal)) {
      return InvalidVcpkgRoot(
        rawRoot: rawRoot,
        issues: List<ValidationIssue>.unmodifiable(issues),
      );
    }
    return ValidVcpkgRoot(rawRoot: rawRoot, layout: layout);
  }
}
