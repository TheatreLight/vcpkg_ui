import 'package:flutter_test/flutter_test.dart';
import 'package:vcpkg_ui/application/regex_filter.dart';
import 'package:vcpkg_ui/domain/package_models.dart';

void main() {
  group('PackageSpec', () {
    test('parses, normalizes, sorts, and deduplicates features', () {
      final PackageSpec specification = PackageSpec.parse(
        'OpenSSL[Tools,Core,tools]:X64-Windows',
      );

      expect(specification.name, 'openssl');
      expect(specification.features, <String>['core', 'tools']);
      expect(specification.vcpkgArgument, 'openssl[core,tools]:x64-windows');
    });

    test('rejects malformed or shell-like package specifications', () {
      for (final String value in <String>[
        'openssl',
        'openssl:x64-windows && whoami',
        r'open ssl:x64-windows',
      ]) {
        expect(
          () => PackageSpec.parse(value),
          throwsA(isA<FormatException>()),
          reason: value,
        );
      }
    });

    test('TargetSlot deduplicates equivalent conditional variants', () {
      final TargetSlot slot = TargetSlot(
        id: 'onnx',
        category: 'ML',
        variants: <PackageSpec>[
          PackageSpec.parse('onnxruntime[core]:x64-windows'),
          PackageSpec.parse('ONNXRUNTIME[core]:X64-WINDOWS'),
          PackageSpec.parse('onnxruntime[core,cuda]:x64-windows'),
        ],
      );

      expect(slot.variants, hasLength(2));
      expect(slot.isConditional, isTrue);
      expect(slot.matchesPackageName('ONNXRUNTIME'), isTrue);
    });
  });

  group('regex package filtering', () {
    const List<String> packages = <String>[
      'boost-asio',
      'boost-filesystem',
      'openssl',
    ];

    test('matches package names case-insensitively', () {
      final RegexFilterResult<String> result = filterByRegex(
        packages,
        r'^BOOST-',
        (String value) => value,
      );

      expect(result.isValid, isTrue);
      expect(result.items, <String>['boost-asio', 'boost-filesystem']);
    });

    test('reports an invalid expression without throwing', () {
      final RegexFilterResult<String> result = filterByRegex(
        packages,
        '[',
        (String value) => value,
      );

      expect(result.isValid, isFalse);
      expect(result.error, isNotEmpty);
      expect(result.items, isEmpty);
    });
  });
}
