import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/application/port_upstream_source_reader.dart';
import 'package:vcpkg_ui/application/vendor_version_config.dart';
import 'package:vcpkg_ui/application/vendor_version_service.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';
import 'package:vcpkg_ui/infrastructure/vendor/configured_vendor_api.dart';
import 'package:vcpkg_ui/infrastructure/vendor/github_vendor_api.dart';
import 'package:vcpkg_ui/infrastructure/vendor/vendor_version_cache.dart';

void main() {
  group('VendorVersionConfigLoader', () {
    test('loads every supported provider and transformation', () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-vendor-config-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final File config = File(path.join(workspace.path, 'sources.json'));
      await config.writeAsString(
        jsonEncode(<String, Object?>{
          'schema': 1,
          'packages': <String, Object?>{
            'tags': <String, Object?>{
              'provider': 'github-tags',
              'repository': 'owner/project',
              'tagPrefix': 'release-',
              'tagRegex': r'^release-(?<version>[0-9_]+)$',
              'comparisonScheme': 'semver',
              'versionTransforms': <Object?>[
                <String, Object?>{'type': 'replace', 'from': '_', 'to': '.'},
              ],
            },
            'index': <String, Object?>{
              'provider': 'http-index',
              'indexUrls': <String>['https://downloads.example.test/pkg/'],
              'entryRegex': r'^pkg-(?<version>[0-9]+(?:\.[0-9]+)+)\.tar\.gz$',
            },
            'commit': <String, Object?>{
              'provider': 'github-commit-date',
              'repository': 'owner/project',
              'branch': 'main',
              'localCommit': '0123456789abcdef0123456789abcdef01234567',
            },
            'meta': <String, Object?>{
              'provider': 'disabled',
              'reason': 'No independent upstream version.',
            },
          },
        }),
      );

      final VendorVersionConfiguration result = await VendorVersionConfigLoader(
        config.path,
      ).load();

      expect(result.packages, hasLength(4));
      final GithubTagsVendorVersionRule tags =
          result.packages['tags']! as GithubTagsVendorVersionRule;
      expect(tags.transformVendorVersion('2_1_0'), '2.1.0');
      expect(tags.comparisonScheme, VcpkgVersionScheme.semver);
      expect(result.packages['index'], isA<HttpIndexVendorVersionRule>());
      expect(
        result.packages['commit'],
        isA<GithubCommitDateVendorVersionRule>(),
      );
      expect(result.packages['meta'], isA<DisabledVendorVersionRule>());
    });

    test('isolates an invalid package rule', () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-vendor-invalid-rule-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final File config = File(path.join(workspace.path, 'sources.json'));
      await config.writeAsString(
        jsonEncode(<String, Object?>{
          'schema': 1,
          'packages': <String, Object?>{
            'broken': <String, Object?>{
              'provider': 'github-tags',
              'repository': 'not-a-repository',
              'tagPrefix': 'v',
              'tagRegex': r'^v(?<version>[0-9.]+)$',
            },
            'disabled': <String, Object?>{
              'provider': 'disabled',
              'reason': 'Intentional.',
            },
          },
        }),
      );

      final VendorVersionConfiguration result = await VendorVersionConfigLoader(
        config.path,
      ).load();

      expect(result.packages['broken'], isA<InvalidVendorVersionRule>());
      expect(result.packages['disabled'], isA<DisabledVendorVersionRule>());
    });

    test('rejects an invalid top-level schema', () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-vendor-invalid-schema-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final File config = File(path.join(workspace.path, 'sources.json'));
      await config.writeAsString('{"schema":2,"packages":{}}');

      expect(
        VendorVersionConfigLoader(config.path).load(),
        throwsA(isA<VendorVersionConfigException>()),
      );
    });
  });

  group('ConfiguredVendorApi', () {
    test('selects the latest transformed GitHub tag and caches it', () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-configured-tags-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final _FakeVendorTransport transport = _FakeVendorTransport(
        (Uri _) => VendorHttpResponse(
          statusCode: HttpStatus.ok,
          body: jsonEncode(<Object?>[
            <String, String>{'ref': 'refs/tags/release-1_9_0'},
            <String, String>{'ref': 'refs/tags/release-2_0_0-rc1'},
            <String, String>{'ref': 'refs/tags/release-2_1_0'},
          ]),
        ),
      );
      final DateTime now = DateTime.utc(2026, 7, 26, 12);
      final ConfiguredVendorApi api = ConfiguredVendorApi(
        cache: VendorVersionCache(
          filePath: path.join(workspace.path, 'cache.json'),
          now: () => now,
        ),
        transport: transport,
        now: () => now,
      );
      final GithubTagsVendorVersionRule rule = GithubTagsVendorVersionRule(
        packageName: 'sample',
        githubRepository: 'owner/project',
        tagPrefix: 'release-',
        tagRegex: r'^release-(?<version>[0-9_]+)$',
        scheme: VcpkgVersionScheme.semver,
        vendorTransforms: const <VersionTextTransform>[
          VersionTextTransform.replace(from: '_', to: '.'),
        ],
      );

      final ConfiguredVendorVersionCandidate fresh = await api.findLatest(
        rule,
        VcpkgVersionScheme.string,
      );
      final ConfiguredVendorVersionCandidate cached = await api.findLatest(
        rule,
        VcpkgVersionScheme.string,
      );

      expect(fresh.version, '2.1.0');
      expect(fresh.reference, 'release-2_1_0');
      expect(fresh.source, VendorVersionSource.githubTag);
      expect(cached.fromCache, isTrue);
      expect(transport.requestedUris, hasLength(1));
      expect(
        transport.requestedUris.single.path,
        '/repos/owner/project/git/matching-refs/tags/release-',
      );
    });

    test('reads only direct same-origin entries from an HTTP index', () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-configured-index-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final _FakeVendorTransport transport = _FakeVendorTransport(
        (Uri _) => const VendorHttpResponse(
          statusCode: HttpStatus.ok,
          body: '''
<a href="pkg-1.9.0.tar.gz">old</a>
<a href="pkg-2.1.0.tar.gz">latest</a>
<a href="pkg-2.2.0-rc1.tar.gz">prerelease</a>
<a href="nested/pkg-9.0.0.tar.gz">nested</a>
<a href="https://elsewhere.test/pkg-10.0.0.tar.gz">external</a>
''',
        ),
      );
      final ConfiguredVendorApi api = ConfiguredVendorApi(
        cache: VendorVersionCache(
          filePath: path.join(workspace.path, 'cache.json'),
        ),
        transport: transport,
      );
      final HttpIndexVendorVersionRule rule = HttpIndexVendorVersionRule(
        packageName: 'sample',
        indexUrls: <Uri>[Uri.parse('https://downloads.example.test/pkg/')],
        entryRegex: r'^pkg-(?<version>[0-9]+(?:\.[0-9]+)+)\.tar\.gz$',
        scheme: VcpkgVersionScheme.semver,
      );

      final ConfiguredVendorVersionCandidate result = await api.findLatest(
        rule,
        VcpkgVersionScheme.string,
      );

      expect(result.version, '2.1.0');
      expect(result.source, VendorVersionSource.httpIndex);
      expect(
        result.url.toString(),
        'https://downloads.example.test/pkg/pkg-2.1.0.tar.gz',
      );
    });

    test(
      'compares a pinned commit date with the configured branch head',
      () async {
        final Directory workspace = await Directory.systemTemp.createTemp(
          'vcpkg-ui-configured-commit-',
        );
        addTearDown(() => workspace.delete(recursive: true));
        const String localSha = '0123456789abcdef0123456789abcdef01234567';
        final _FakeVendorTransport transport = _FakeVendorTransport((Uri uri) {
          final bool local = uri.path.endsWith(localSha);
          return VendorHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(<String, Object?>{
              'sha': local
                  ? localSha
                  : 'abcdef0123456789abcdef0123456789abcdef01',
              'html_url': 'https://github.com/owner/project/commit/latest',
              'commit': <String, Object?>{
                'committer': <String, String>{
                  'date': local
                      ? '2025-03-10T10:00:00Z'
                      : '2026-07-25T20:00:00Z',
                },
              },
            }),
          );
        });
        final ConfiguredVendorApi api = ConfiguredVendorApi(
          cache: VendorVersionCache(
            filePath: path.join(workspace.path, 'cache.json'),
          ),
          transport: transport,
        );

        final ConfiguredVendorVersionCandidate result = await api.findLatest(
          const GithubCommitDateVendorVersionRule(
            packageName: 'sample',
            githubRepository: 'owner/project',
            branch: 'main',
            localCommit: localSha,
          ),
          VcpkgVersionScheme.string,
        );

        expect(result.comparisonLocalVersion, '2025-03-10');
        expect(result.version, '2026-07-25');
        expect(result.source, VendorVersionSource.githubCommit);
        expect(transport.requestedUris, hasLength(2));
      },
    );

    test('reports GitHub rate limiting distinctly', () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-configured-limit-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final ConfiguredVendorApi api = ConfiguredVendorApi(
        cache: VendorVersionCache(
          filePath: path.join(workspace.path, 'cache.json'),
        ),
        transport: _FakeVendorTransport(
          (Uri _) => const VendorHttpResponse(
            statusCode: HttpStatus.forbidden,
            body: '{}',
            rateLimitRemaining: '0',
          ),
        ),
      );

      expect(
        api.findLatest(
          GithubTagsVendorVersionRule(
            packageName: 'sample',
            githubRepository: 'owner/project',
            tagPrefix: 'v',
            tagRegex: r'^v(?<version>[0-9.]+)$',
          ),
          VcpkgVersionScheme.semver,
        ),
        throwsA(isA<ConfiguredVendorRateLimitException>()),
      );
    });
  });

  test('configured rules take priority over automatic discovery', () async {
    final Directory workspace = await Directory.systemTemp.createTemp(
      'vcpkg-ui-configured-priority-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final Directory portDirectory = Directory(
      path.join(workspace.path, 'alpha'),
    );
    await portDirectory.create();
    final File manifest = File(path.join(portDirectory.path, 'vcpkg.json'));
    await manifest.writeAsString('{}');
    await File(path.join(portDirectory.path, 'portfile.cmake')).writeAsString(
      r'vcpkg_from_github(REPO automatic/source REF "v${VERSION}" SHA512 00)',
    );
    final File config = File(path.join(workspace.path, 'sources.json'));
    await config.writeAsString(
      jsonEncode(<String, Object?>{
        'schema': 1,
        'packages': <String, Object?>{
          'alpha': <String, Object?>{
            'provider': 'github-tags',
            'repository': 'configured/source',
            'tagPrefix': 'v',
            'tagRegex': r'^v(?<version>[0-9]+(?:\.[0-9]+)+)$',
          },
        },
      }),
    );
    final _NeverGithubClient github = _NeverGithubClient();
    final _FixedConfiguredClient configured = _FixedConfiguredClient();
    final VendorVersionService service = VendorVersionService(
      sourceReader: const PortUpstreamSourceReader(),
      githubClient: github,
      configurationLoader: VendorVersionConfigLoader(config.path),
      configuredClient: configured,
    );

    final VendorVersionScanResult result = await service.check(
      plan: FullInstallPlan(
        slots: <TargetSlot>[
          TargetSlot(
            id: 'alpha',
            category: 'test',
            variants: <PackageSpec>[
              PackageSpec(name: 'alpha', triplet: 'x64-windows'),
            ],
          ),
        ],
      ),
      catalog: <PackageViewState>[
        PackageViewState(
          metadata: PortMetadata(
            name: 'alpha',
            availableVersion: '1.0.0',
            sourceVersion: '1.0.0',
            versionScheme: VcpkgVersionScheme.semver,
            manifestPath: manifest.path,
          ),
        ),
      ],
    );

    final VendorVersionInfo alpha = result.packages['alpha']!;
    expect(alpha.status, VendorVersionStatus.updateAvailable);
    expect(alpha.repository, 'configured/source');
    expect(alpha.ruleOrigin, VendorVersionRuleOrigin.configuration);
    expect(github.calls, 0);
    expect(configured.calls, 1);
  });
}

final class _FakeVendorTransport implements VendorHttpTransport {
  _FakeVendorTransport(this.responseFor);

  final VendorHttpResponse Function(Uri uri) responseFor;
  final List<Uri> requestedUris = <Uri>[];

  @override
  Future<VendorHttpResponse> get(Uri uri) async {
    requestedUris.add(uri);
    return responseFor(uri);
  }
}

final class _NeverGithubClient implements GithubVersionClient {
  var calls = 0;

  @override
  Future<GithubVersionCandidate> findLatest(
    GithubPortSource source,
    VcpkgVersionScheme scheme,
  ) async {
    calls++;
    throw StateError('Automatic GitHub discovery must not run.');
  }
}

final class _FixedConfiguredClient implements ConfiguredVendorVersionClient {
  var calls = 0;

  @override
  Future<ConfiguredVendorVersionCandidate> findLatest(
    VendorVersionRule rule,
    VcpkgVersionScheme fallbackScheme,
  ) async {
    calls++;
    return ConfiguredVendorVersionCandidate(
      version: '2.0.0',
      reference: 'v2.0.0',
      url: Uri.parse('https://github.com/configured/source/tree/v2.0.0'),
      source: VendorVersionSource.githubTag,
      checkedAt: DateTime.utc(2026, 7, 26),
    );
  }
}
