import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/infrastructure/process/process_command.dart';

final class VcpkgLayout {
  const VcpkgLayout({
    required this.rootDirectory,
    required this.rootMarkerPath,
    required this.portsDirectory,
    required this.executablePath,
    required this.removeAllScriptPath,
    required this.fullInstallScriptPath,
  });

  final String rootDirectory;
  final String rootMarkerPath;
  final String portsDirectory;
  final String executablePath;
  final String removeAllScriptPath;
  final String fullInstallScriptPath;
}

enum ArtifactKind { file, directory }

final class RequiredArtifact {
  const RequiredArtifact({
    required this.code,
    required this.path,
    required this.kind,
    required this.description,
  });

  final String code;
  final String path;
  final ArtifactKind kind;
  final String description;
}

final class ValidationIssue {
  const ValidationIssue({
    required this.code,
    required this.message,
    this.path,
    this.isFatal = true,
  });

  final String code;
  final String message;
  final String? path;
  final bool isFatal;
}

abstract interface class VcpkgPlatformAdapter {
  String get platformId;

  VcpkgLayout createLayout(String rawRoot);

  List<RequiredArtifact> requiredArtifacts(VcpkgLayout layout);

  List<ValidationIssue> validateLayout(VcpkgLayout layout);

  String defaultTriplet(Map<String, String> environment);

  ProcessCommand listInstalledCommand(VcpkgLayout layout);

  ProcessCommand packageInfoCommand(VcpkgLayout layout, String packageName);

  ProcessCommand installCommand(VcpkgLayout layout, PackageSpec specification);

  ProcessCommand removePreviewCommand(
    VcpkgLayout layout,
    PackageSpec specification,
  );

  ProcessCommand removeCommand(
    VcpkgLayout layout,
    PackageSpec specification, {
    required bool recurse,
  });

  ProcessCommand removeAllCommand(VcpkgLayout layout);

  ProcessCommand upgradePreviewCommand(VcpkgLayout layout);

  ProcessCommand upgradeAllCommand(VcpkgLayout layout);

  ProcessCommand fullInstallCommand(VcpkgLayout layout);

  String logDirectoryPath(
    Map<String, String> environment, {
    VcpkgLayout? layout,
  });

  Future<void> openLogFile(String filePath);
}
