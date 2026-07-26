import 'dart:io';

import '../domain/package_models.dart';

abstract interface class FullInstallPlanReader {
  Future<FullInstallPlan> read(String scriptPath);
}

class FullInstallPlanFormatException implements Exception {
  const FullInstallPlanFormatException(this.message);

  final String message;

  @override
  String toString() => 'FullInstallPlanFormatException: $message';
}

/// Read-only parser for the category declarations in
/// the configured full-install script.
class WindowsBatchFullInstallPlanReader implements FullInstallPlanReader {
  const WindowsBatchFullInstallPlanReader();

  static final RegExp _assignmentPattern = RegExp(
    r'^\s*set\s+"?([A-Za-z_][A-Za-z0-9_]*)=(.*?)"?\s*$',
    caseSensitive: false,
  );
  static final RegExp _categoryPattern = RegExp(
    r'^\s*call\s+:INSTALL_CATEGORY\s+"([^"]+)"\s+"%([A-Za-z_][A-Za-z0-9_]*)%"',
    caseSensitive: false,
  );
  static final RegExp _variableTokenPattern = RegExp(
    r'^%([A-Za-z_][A-Za-z0-9_]*)%$',
  );
  static final RegExp _variableReferencePattern = RegExp(
    r'%([A-Za-z_][A-Za-z0-9_]*)%',
  );

  @override
  Future<FullInstallPlan> read(String scriptPath) async {
    final file = File(scriptPath);
    if (!await file.exists()) {
      throw FullInstallPlanFormatException(
        'Full-install script does not exist: $scriptPath',
      );
    }

    final text = await file.readAsString();
    return parse(text);
  }

  FullInstallPlan parse(String scriptText) {
    final logicalLines = _joinContinuationLines(
      scriptText.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n'),
    );
    final assignments = <String, List<String>>{};
    final categoryDeclarations = <({String name, String variable})>[];

    for (final line in logicalLines) {
      final assignment = _assignmentPattern.firstMatch(line);
      if (assignment != null) {
        final name = assignment.group(1)!.toUpperCase();
        final value = assignment.group(2)!.trim();
        if (value.isNotEmpty) {
          assignments.putIfAbsent(name, () => <String>[]).add(value);
        }
      }

      final category = _categoryPattern.firstMatch(line);
      if (category != null) {
        categoryDeclarations.add((
          name: category.group(1)!.trim(),
          variable: category.group(2)!.toUpperCase(),
        ));
      }
    }

    if (categoryDeclarations.isEmpty) {
      throw const FullInstallPlanFormatException(
        'No INSTALL_CATEGORY declarations were found.',
      );
    }

    final slots = <TargetSlot>[];
    final warnings = <String>[];
    final seenStaticSpecifications = <String>{};

    for (
      var categoryIndex = 0;
      categoryIndex < categoryDeclarations.length;
      categoryIndex++
    ) {
      final declaration = categoryDeclarations[categoryIndex];
      final categoryValues = assignments[declaration.variable];
      if (categoryValues == null || categoryValues.length != 1) {
        throw FullInstallPlanFormatException(
          'Category "${declaration.name}" must have exactly one '
          '${declaration.variable} assignment.',
        );
      }

      final tokens = _splitPackageTokens(categoryValues.single);
      if (tokens.isEmpty) {
        throw FullInstallPlanFormatException(
          'Category "${declaration.name}" contains no package targets.',
        );
      }

      for (var tokenIndex = 0; tokenIndex < tokens.length; tokenIndex++) {
        final token = tokens[tokenIndex];
        final variableMatch = _variableTokenPattern.firstMatch(token);
        final variants = variableMatch == null
            ? <PackageSpec>[
                _parseResolvedSpec(token, assignments, const <String>{}),
              ]
            : _resolveSymbolicVariants(variableMatch.group(1)!, assignments);

        final uniqueVariants = <String, PackageSpec>{
          for (final variant in variants) variant.canonicalKey: variant,
        }.values.toList(growable: false);
        if (uniqueVariants.isEmpty) {
          throw FullInstallPlanFormatException(
            'Target "$token" in "${declaration.name}" has no variants.',
          );
        }

        final packageNames = uniqueVariants.map((item) => item.name).toSet();
        if (packageNames.length != 1) {
          throw FullInstallPlanFormatException(
            'Symbolic target "$token" resolves to different package names: '
            '${packageNames.join(', ')}.',
          );
        }

        if (uniqueVariants.length == 1 &&
            !seenStaticSpecifications.add(uniqueVariants.single.canonicalKey)) {
          warnings.add(
            'Duplicate target ${uniqueVariants.single.vcpkgArgument} in '
            '${declaration.name} was counted once.',
          );
          continue;
        }

        slots.add(
          TargetSlot(
            id:
                '${categoryIndex + 1}:${tokenIndex + 1}:'
                '${uniqueVariants.first.name}',
            category: declaration.name,
            variants: uniqueVariants,
          ),
        );
      }
    }

    if (slots.isEmpty) {
      throw const FullInstallPlanFormatException(
        'Full-install plan contains no target slots.',
      );
    }
    return FullInstallPlan(slots: slots, warnings: warnings);
  }

  List<String> _joinContinuationLines(List<String> physicalLines) {
    final result = <String>[];
    for (var index = 0; index < physicalLines.length; index++) {
      var line = physicalLines[index];
      final trimmed = line.trimRight();
      if (!_assignmentPattern.hasMatch(trimmed) || !trimmed.endsWith('^')) {
        result.add(line);
        continue;
      }

      final buffer = StringBuffer(trimmed.substring(0, trimmed.length - 1));
      while (++index < physicalLines.length) {
        line = physicalLines[index];
        final continuation = line.trim();
        if (continuation.isEmpty || _isComment(continuation)) {
          break;
        }
        buffer
          ..write(' ')
          ..write(
            continuation.endsWith('^')
                ? continuation.substring(0, continuation.length - 1).trimRight()
                : continuation,
          );
        if (!continuation.endsWith('^')) {
          break;
        }
      }
      result.add(buffer.toString());
    }
    return result;
  }

  bool _isComment(String line) {
    final lower = line.toLowerCase();
    return lower == 'rem' || lower.startsWith('rem ') || lower.startsWith('::');
  }

  List<String> _splitPackageTokens(String value) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var featureDepth = 0;

    void commit() {
      final token = buffer.toString().trim();
      if (token.isNotEmpty) {
        tokens.add(token);
      }
      buffer.clear();
    }

    for (var index = 0; index < value.length; index++) {
      final character = value[index];
      if (character == '[') {
        featureDepth++;
      } else if (character == ']' && featureDepth > 0) {
        featureDepth--;
      }
      if ((character == ' ' || character == '\t') && featureDepth == 0) {
        commit();
      } else {
        buffer.write(character);
      }
    }
    commit();
    return tokens;
  }

  List<PackageSpec> _resolveSymbolicVariants(
    String variableName,
    Map<String, List<String>> assignments,
  ) {
    final normalized = variableName.toUpperCase();
    final values = assignments[normalized];
    if (values == null || values.isEmpty) {
      throw FullInstallPlanFormatException(
        'Symbolic target %$variableName% has no assignments.',
      );
    }
    return values
        .map(
          (value) =>
              _parseResolvedSpec(value, assignments, <String>{normalized}),
        )
        .toList(growable: false);
  }

  PackageSpec _parseResolvedSpec(
    String value,
    Map<String, List<String>> assignments,
    Set<String> resolving,
  ) {
    var resolved = value.trim();
    for (var pass = 0; pass < 16; pass++) {
      final references = _variableReferencePattern
          .allMatches(resolved)
          .toList();
      if (references.isEmpty) {
        try {
          return PackageSpec.parse(resolved);
        } on FormatException catch (error) {
          throw FullInstallPlanFormatException(
            'Invalid package specification "$resolved": ${error.message}',
          );
        }
      }

      var changed = false;
      for (final reference in references.reversed) {
        final variable = reference.group(1)!.toUpperCase();
        final values = assignments[variable];
        if (values == null || values.isEmpty) {
          throw FullInstallPlanFormatException(
            'Unknown variable %$variable% in package specification "$value".',
          );
        }
        final uniqueValues = values.toSet();
        if (uniqueValues.length != 1) {
          throw FullInstallPlanFormatException(
            'Nested variable %$variable% is conditional and cannot be '
            'resolved inside "$value".',
          );
        }
        if (resolving.contains(variable)) {
          throw FullInstallPlanFormatException(
            'Cyclic variable reference %$variable% in "$value".',
          );
        }
        resolved = resolved.replaceRange(
          reference.start,
          reference.end,
          uniqueValues.single,
        );
        changed = true;
      }
      if (!changed) {
        break;
      }
    }
    throw FullInstallPlanFormatException(
      'Could not resolve package specification "$value".',
    );
  }
}
