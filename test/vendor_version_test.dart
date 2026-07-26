import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/application/port_upstream_source_reader.dart';
import 'package:vcpkg_ui/application/vcpkg_version_comparator.dart';
import 'package:vcpkg_ui/application/vendor_version_log_formatter.dart';
import 'package:vcpkg_ui/application/vendor_version_service.dart';
import 'package:vcpkg_ui/domain/package_models.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';
import 'package:vcpkg_ui/infrastructure/vendor/github_vendor_api.dart';
import 'package:vcpkg_ui/infrastructure/vendor/vendor_version_cache.dart';

void main() {
  group('PortUpstreamSourceReader', () {
    const PortUpstreamSourceReader reader = PortUpstreamSourceReader();

    test('recognizes a static GitHub source and VERSION tag pattern', () {
      final PortUpstreamSourceResult result = reader.parse(r'''
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO grpc/grpc
    REF "v${VERSION}"
    SHA512 0123456789
)
''');

      expect(result.isSupported, isTrue);
      expect(result.source!.repository, 'grpc/grpc');
      expect(result.source!.tagForVersion('1.2.3'), 'v1.2.3');
      expect(result.source!.versionFromTag('v2.0.0'), '2.0.0');
      expect(result.source!.versionFromTag('release-2.0.0'), isNull);
    });

    test('marks custom sources and dynamic refs as unsupported', () {
      final PortUpstreamSourceResult download = reader.parse('''
vcpkg_download_distfile(ARCHIVE URLS https://example.test/a.zip)
''');
      final PortUpstreamSourceResult dynamicRef = reader.parse(r'''
vcpkg_from_github(
  REPO owner/project
  REF "${GIT_REF}"
  SHA512 0123456789
)
''');

      expect(download.isSupported, isFalse);
      expect(download.reason, contains('Download URL'));
      expect(dynamicRef.isSupported, isFalse);
      expect(dynamicRef.reason, contains(r'${VERSION}'));
    });

    test('recognizes a GitHub release download URL', () {
      final PortUpstreamSourceResult result = reader.parse(r'''
vcpkg_download_distfile(
  ARCHIVE
  URLS "https://github.com/unicode-org/icu/releases/download/release-${VERSION}/icu4c.tgz"
  SHA512 00
)
''');

      expect(result.isSupported, isTrue);
      expect(result.source!.repository, 'unicode-org/icu');
      expect(result.source!.tagForVersion('78-1'), 'release-78-1');
    });

    test('infers primary and archive indexes from an Apache URL', () {
      final PortUpstreamSourceResult result = reader.parse(r'''
vcpkg_download_distfile(
  ARCHIVE
  URLS "https://archive.apache.org/dist/arrow/arrow-${VERSION}/apache-arrow.tar.gz"
  SHA512 00
)
''');

      expect(result.isSupported, isTrue);
      expect(
        result.httpIndexSource!.indexUrls.map((Uri uri) => uri.toString()),
        <String>[
          'https://downloads.apache.org/arrow/',
          'https://archive.apache.org/dist/arrow/',
        ],
      );
      expect(
        RegExp(
          result.httpIndexSource!.entryRegex,
        ).firstMatch('arrow-22.0.0/')?.namedGroup('version'),
        '22.0.0',
      );
    });
  });

  group('VcpkgVersionComparator', () {
    const VcpkgVersionComparator comparator = VcpkgVersionComparator();

    test('compares supported vcpkg version schemes conservatively', () {
      expect(
        comparator.compare('1.9.0', '1.10.0', VcpkgVersionScheme.semver),
        lessThan(0),
      );
      expect(
        comparator.compare('35.1', '35.2', VcpkgVersionScheme.relaxed),
        lessThan(0),
      );
      expect(
        comparator.compare(
          '2026-07-01',
          '2026-07-01.1',
          VcpkgVersionScheme.date,
        ),
        lessThan(0),
      );
      expect(
        comparator.compare('release-a', 'release-b', VcpkgVersionScheme.string),
        isNull,
      );
    });

    test('does not treat prerelease semver tags as stable', () {
      expect(
        comparator.isStable('2.0.0-rc.1', VcpkgVersionScheme.semver),
        isFalse,
      );
      expect(comparator.isStable('2.0.0', VcpkgVersionScheme.semver), isTrue);
    });
  });

  group('GithubVendorApi', () {
    test('expires cached results after the configured TTL', () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-vendor-cache-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      DateTime now = DateTime(2026, 7, 25, 12);
      final VendorVersionCache cache = VendorVersionCache(
        filePath: path.join(workspace.path, 'vendor-cache.json'),
        now: () => now,
      );
      final CachedVendorVersion value = CachedVendorVersion(
        version: '1.2.3',
        tag: 'v1.2.3',
        url: Uri.parse('https://github.com/owner/project/releases/tag/v1.2.3'),
        source: VendorVersionSource.githubRelease,
        checkedAt: DateTime(2026, 7, 25, 12),
      );

      await cache.write('owner/project|v||semver', value);
      expect(await cache.read('owner/project|v||semver'), isNotNull);
      now = now.add(const Duration(hours: 25));
      expect(await cache.read('owner/project|v||semver'), isNull);
    });

    test(
      'uses the latest stable release and then the persistent cache',
      () async {
        final Directory workspace = await Directory.systemTemp.createTemp(
          'vcpkg-ui-vendor-api-',
        );
        addTearDown(() => workspace.delete(recursive: true));
        final DateTime now = DateTime(2026, 7, 25, 12);
        final _QueueGithubTransport transport = _QueueGithubTransport(
          <GithubHttpResponse>[
            GithubHttpResponse(
              statusCode: HttpStatus.ok,
              body: jsonEncode(<String, Object?>{
                'tag_name': 'v2.1.0',
                'html_url':
                    'https://github.com/owner/project/releases/tag/v2.1.0',
                'draft': false,
                'prerelease': false,
              }),
            ),
          ],
        );
        final GithubVendorApi api = GithubVendorApi(
          cache: VendorVersionCache(
            filePath: path.join(workspace.path, 'vendor-cache.json'),
            now: () => now,
          ),
          transport: transport,
          now: () => now,
        );
        const GithubPortSource source = GithubPortSource(
          repository: 'owner/project',
          tagPrefix: 'v',
          tagSuffix: '',
        );

        final GithubVersionCandidate fresh = await api.findLatest(
          source,
          VcpkgVersionScheme.semver,
        );
        final GithubVersionCandidate cached = await api.findLatest(
          source,
          VcpkgVersionScheme.semver,
        );

        expect(fresh.version, '2.1.0');
        expect(fresh.source, VendorVersionSource.githubRelease);
        expect(fresh.fromCache, isFalse);
        expect(cached.fromCache, isTrue);
        expect(transport.requestedUris, hasLength(1));
      },
    );

    test(
      'falls back to tags and selects the greatest stable version',
      () async {
        final Directory workspace = await Directory.systemTemp.createTemp(
          'vcpkg-ui-vendor-tags-',
        );
        addTearDown(() => workspace.delete(recursive: true));
        final _QueueGithubTransport transport = _QueueGithubTransport(
          <GithubHttpResponse>[
            const GithubHttpResponse(
              statusCode: HttpStatus.notFound,
              body: '{}',
            ),
            GithubHttpResponse(
              statusCode: HttpStatus.ok,
              body: jsonEncode(<Map<String, String>>[
                <String, String>{'name': 'v2.0.0-rc.1'},
                <String, String>{'name': 'v1.9.0'},
                <String, String>{'name': 'v2.0.0'},
                <String, String>{'name': 'unrelated'},
              ]),
            ),
          ],
        );
        final GithubVendorApi api = GithubVendorApi(
          cache: VendorVersionCache(
            filePath: path.join(workspace.path, 'vendor-cache.json'),
          ),
          transport: transport,
        );

        final GithubVersionCandidate result = await api.findLatest(
          const GithubPortSource(
            repository: 'owner/tags-only',
            tagPrefix: 'v',
            tagSuffix: '',
          ),
          VcpkgVersionScheme.semver,
        );

        expect(result.version, '2.0.0');
        expect(result.source, VendorVersionSource.githubTag);
        expect(transport.requestedUris, hasLength(2));
        expect(transport.requestedUris.last.queryParameters['per_page'], '100');
      },
    );

    test('reports the GitHub primary rate limit distinctly', () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-vendor-limit-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final GithubVendorApi api = GithubVendorApi(
        cache: VendorVersionCache(
          filePath: path.join(workspace.path, 'vendor-cache.json'),
        ),
        transport: _QueueGithubTransport(const <GithubHttpResponse>[
          GithubHttpResponse(
            statusCode: HttpStatus.forbidden,
            body: '{}',
            rateLimitRemaining: '0',
          ),
        ]),
      );

      expect(
        api.findLatest(
          const GithubPortSource(
            repository: 'owner/project',
            tagPrefix: 'v',
            tagSuffix: '',
          ),
          VcpkgVersionScheme.semver,
        ),
        throwsA(isA<GithubRateLimitException>()),
      );
    });

    test('reports an inconclusive release and tag lookup distinctly', () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-vendor-not-found-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final GithubVendorApi api = GithubVendorApi(
        cache: VendorVersionCache(
          filePath: path.join(workspace.path, 'vendor-cache.json'),
        ),
        transport: _QueueGithubTransport(const <GithubHttpResponse>[
          GithubHttpResponse(statusCode: HttpStatus.notFound, body: '{}'),
          GithubHttpResponse(statusCode: HttpStatus.ok, body: '[]'),
        ]),
      );

      expect(
        api.findLatest(
          const GithubPortSource(
            repository: 'owner/monorepo',
            tagPrefix: 'package_',
            tagSuffix: '',
          ),
          VcpkgVersionScheme.semver,
        ),
        throwsA(
          isA<GithubVersionNotFoundException>().having(
            (GithubVersionNotFoundException error) => error.message,
            'message',
            contains('first 100 tags'),
          ),
        ),
      );
    });
  });

  test(
    'VendorVersionService checks only full-install ports and deduplicates sources',
    () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-vendor-service-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final PortMetadata alpha = await _writePort(workspace, 'alpha', r'''
vcpkg_from_github(REPO owner/shared REF "v${VERSION}" SHA512 00)
''');
      final PortMetadata beta = await _writePort(workspace, 'beta', r'''
vcpkg_from_github(REPO owner/shared REF "v${VERSION}" SHA512 00)
''');
      final PortMetadata custom = await _writePort(
        workspace,
        'custom',
        'vcpkg_download_distfile(ARCHIVE URLS https://example.test/a.zip)',
      );
      final PortMetadata outside = await _writePort(workspace, 'outside', r'''
vcpkg_from_github(REPO owner/outside REF "v${VERSION}" SHA512 00)
''');
      final _FakeGithubVersionClient github = _FakeGithubVersionClient();
      final VendorVersionService service = VendorVersionService(
        sourceReader: const PortUpstreamSourceReader(),
        githubClient: github,
      );
      final List<VendorVersionCheckProgress> progress =
          <VendorVersionCheckProgress>[];

      final VendorVersionScanResult result = await service.check(
        plan: FullInstallPlan(
          slots: <TargetSlot>[_slot('alpha'), _slot('beta'), _slot('custom')],
        ),
        catalog: <PackageViewState>[
          PackageViewState(metadata: alpha),
          PackageViewState(metadata: beta),
          PackageViewState(metadata: custom),
          PackageViewState(metadata: outside),
        ],
        onProgress: progress.add,
      );

      expect(
        result.packages.keys,
        containsAll(<String>['alpha', 'beta', 'custom']),
      );
      expect(result.packages, isNot(contains('outside')));
      expect(
        result.packages['alpha']!.status,
        VendorVersionStatus.updateAvailable,
      );
      expect(
        result.packages['beta']!.status,
        VendorVersionStatus.updateAvailable,
      );
      expect(
        result.packages['custom']!.status,
        VendorVersionStatus.unsupported,
      );
      expect(github.calls, 1);
      expect(progress.first.completed, 0);
      expect(progress.last.completed, 3);
      expect(progress.last.total, 3);
    },
  );

  test(
    'VendorVersionService marks an inconclusive lookup as unsupported',
    () async {
      final Directory workspace = await Directory.systemTemp.createTemp(
        'vcpkg-ui-vendor-unsupported-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final PortMetadata alpha = await _writePort(workspace, 'alpha', r'''
vcpkg_from_github(REPO owner/monorepo REF "package_${VERSION}" SHA512 00)
''');
      final VendorVersionService service = VendorVersionService(
        sourceReader: const PortUpstreamSourceReader(),
        githubClient: const _NotFoundGithubVersionClient(),
      );

      final VendorVersionScanResult result = await service.check(
        plan: FullInstallPlan(slots: <TargetSlot>[_slot('alpha')]),
        catalog: <PackageViewState>[PackageViewState(metadata: alpha)],
      );

      final VendorVersionInfo package = result.packages['alpha']!;
      expect(package.status, VendorVersionStatus.unsupported);
      expect(package.repository, 'owner/monorepo');
      expect(package.reason, contains('first 100 tags'));
    },
  );

  test('VendorVersionLogFormatter records package diagnostics and summary', () {
    final VendorVersionScanResult result = VendorVersionScanResult(
      packages: <String, VendorVersionInfo>{
        'update': VendorVersionInfo(
          packageName: 'update',
          status: VendorVersionStatus.updateAvailable,
          localVersion: '1.0.0',
          vendorVersion: '2.0.0',
          repository: 'owner/update',
          source: VendorVersionSource.githubRelease,
          releaseUrl: Uri.parse('https://github.com/owner/update/releases/2'),
          checkedAt: DateTime.utc(2026, 7, 26),
        ),
        'failed': const VendorVersionInfo(
          packageName: 'failed',
          status: VendorVersionStatus.checkFailed,
          localVersion: '1.0.0',
          repository: 'owner/failed',
          reason: 'HTTP 500 from GitHub.',
        ),
        'unsupported': const VendorVersionInfo(
          packageName: 'unsupported',
          status: VendorVersionStatus.unsupported,
          localVersion: '3.0.0',
          reason: 'No supported source.',
        ),
      },
    );

    const VendorVersionLogFormatter formatter = VendorVersionLogFormatter();
    final List<String> details = formatter.details(result);

    expect(details.first, startsWith('[FAILED] failed'));
    expect(details.first, contains('repository=owner/failed'));
    expect(details.first, contains('reason=HTTP 500 from GitHub.'));
    expect(details[1], contains('local=1.0.0 | vendor=2.0.0'));
    expect(details.last, contains('[UNSUPPORTED] unsupported'));
    expect(
      formatter.summary(result),
      'Vendor version check completed: 1 update(s), 0 current, '
      '1 unsupported, 1 failed, 0 rate limited.',
    );
  });
}

final class _QueueGithubTransport implements GithubHttpTransport {
  _QueueGithubTransport(this.responses);

  final List<GithubHttpResponse> responses;
  final List<Uri> requestedUris = <Uri>[];
  var _nextResponse = 0;

  @override
  Future<GithubHttpResponse> get(Uri uri) async {
    requestedUris.add(uri);
    if (_nextResponse >= responses.length) {
      throw StateError('No fake GitHub response remains for $uri.');
    }
    return responses[_nextResponse++];
  }
}

final class _FakeGithubVersionClient implements GithubVersionClient {
  int calls = 0;

  @override
  Future<GithubVersionCandidate> findLatest(
    GithubPortSource source,
    VcpkgVersionScheme scheme,
  ) async {
    calls++;
    return GithubVersionCandidate(
      version: '2.0.0',
      tag: 'v2.0.0',
      url: Uri.parse(
        'https://github.com/${source.repository}/releases/tag/v2.0.0',
      ),
      source: VendorVersionSource.githubRelease,
      checkedAt: DateTime(2026, 7, 25),
    );
  }
}

final class _NotFoundGithubVersionClient implements GithubVersionClient {
  const _NotFoundGithubVersionClient();

  @override
  Future<GithubVersionCandidate> findLatest(
    GithubPortSource source,
    VcpkgVersionScheme scheme,
  ) => throw const GithubVersionNotFoundException(
    'No comparable matching tag was found among the first 100 tags.',
  );
}

Future<PortMetadata> _writePort(
  Directory workspace,
  String name,
  String portfile,
) async {
  final Directory directory = Directory(path.join(workspace.path, name));
  await directory.create();
  final File manifest = File(path.join(directory.path, 'vcpkg.json'));
  await manifest.writeAsString('{}');
  await File(
    path.join(directory.path, 'portfile.cmake'),
  ).writeAsString(portfile);
  return PortMetadata(
    name: name,
    availableVersion: '1.0.0',
    sourceVersion: '1.0.0',
    versionScheme: VcpkgVersionScheme.semver,
    manifestPath: manifest.path,
  );
}

TargetSlot _slot(String packageName) => TargetSlot(
  id: packageName,
  category: 'test',
  variants: <PackageSpec>[
    PackageSpec(name: packageName, triplet: 'x64-windows'),
  ],
);
