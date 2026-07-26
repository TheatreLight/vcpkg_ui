import 'dart:convert';
import 'dart:io';

import 'package:vcpkg_ui/application/port_upstream_source_reader.dart';
import 'package:vcpkg_ui/application/vcpkg_version_comparator.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';
import 'package:vcpkg_ui/infrastructure/vendor/vendor_version_cache.dart';

final class GithubRateLimitException implements Exception {
  const GithubRateLimitException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GithubVendorApiException implements Exception {
  const GithubVendorApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class GithubVersionNotFoundException extends GithubVendorApiException {
  const GithubVersionNotFoundException(super.message);
}

final class GithubVersionCandidate {
  const GithubVersionCandidate({
    required this.version,
    required this.tag,
    required this.url,
    required this.source,
    required this.checkedAt,
    this.fromCache = false,
  });

  final String version;
  final String tag;
  final Uri url;
  final VendorVersionSource source;
  final DateTime checkedAt;
  final bool fromCache;
}

abstract interface class GithubVersionClient {
  Future<GithubVersionCandidate> findLatest(
    GithubPortSource source,
    VcpkgVersionScheme scheme,
  );
}

final class GithubHttpResponse {
  const GithubHttpResponse({
    required this.statusCode,
    required this.body,
    this.rateLimitRemaining,
  });

  final int statusCode;
  final String body;
  final String? rateLimitRemaining;
}

abstract interface class GithubHttpTransport {
  Future<GithubHttpResponse> get(Uri uri);
}

final class IoGithubHttpTransport implements GithubHttpTransport {
  IoGithubHttpTransport({
    this.environment = const <String, String>{},
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient();

  final Map<String, String> environment;
  final HttpClient _httpClient;

  static const Duration _requestTimeout = Duration(seconds: 15);

  @override
  Future<GithubHttpResponse> get(Uri uri) async {
    final HttpClientRequest request = await _httpClient
        .getUrl(uri)
        .timeout(_requestTimeout);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'vcpkg-ui');
    final String? token = environment['GITHUB_TOKEN']?.trim();
    if (token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    final HttpClientResponse response = await request.close().timeout(
      _requestTimeout,
    );
    final String body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(_requestTimeout);
    return GithubHttpResponse(
      statusCode: response.statusCode,
      body: body,
      rateLimitRemaining: response.headers.value('x-ratelimit-remaining'),
    );
  }
}

final class GithubVendorApi implements GithubVersionClient {
  GithubVendorApi({
    required this.cache,
    Map<String, String> environment = const <String, String>{},
    GithubHttpTransport? transport,
    this.comparator = const VcpkgVersionComparator(),
    DateTime Function()? now,
  }) : transport = transport ?? IoGithubHttpTransport(environment: environment),
       _now = now ?? DateTime.now;

  final VendorVersionCache cache;
  final GithubHttpTransport transport;
  final VcpkgVersionComparator comparator;
  final DateTime Function() _now;

  @override
  Future<GithubVersionCandidate> findLatest(
    GithubPortSource source,
    VcpkgVersionScheme scheme,
  ) async {
    final String cacheKey = <String>[
      source.repository,
      source.tagPrefix,
      source.tagSuffix,
      scheme.name,
    ].join('|');
    final CachedVendorVersion? cached = await cache.read(cacheKey);
    if (cached != null) {
      return GithubVersionCandidate(
        version: cached.version,
        tag: cached.tag,
        url: cached.url,
        source: cached.source,
        checkedAt: cached.checkedAt,
        fromCache: true,
      );
    }

    GithubVersionCandidate? candidate = await _latestRelease(source);
    candidate ??= await _latestTag(source, scheme);
    if (candidate == null) {
      throw GithubVersionNotFoundException(
        'No stable GitHub release matched REF and no comparable matching tag '
        'was found among the first 100 tags.',
      );
    }
    await cache.write(
      cacheKey,
      CachedVendorVersion(
        version: candidate.version,
        tag: candidate.tag,
        url: candidate.url,
        source: candidate.source,
        checkedAt: candidate.checkedAt,
      ),
    );
    return candidate;
  }

  Future<GithubVersionCandidate?> _latestRelease(
    GithubPortSource source,
  ) async {
    final GithubHttpResponse response = await transport.get(
      Uri.https(
        'api.github.com',
        '/repos/${source.repository}/releases/latest',
      ),
    );
    if (response.statusCode == HttpStatus.notFound) {
      return null;
    }
    _ensureSuccessful(response, source.repository);
    final Object? decoded = _decodeJson(response.body);
    if (decoded is! Map<String, dynamic> ||
        decoded['draft'] == true ||
        decoded['prerelease'] == true) {
      return null;
    }
    final String? tag = decoded['tag_name'] as String?;
    final String? version = tag == null ? null : source.versionFromTag(tag);
    final Uri? url = Uri.tryParse(decoded['html_url'] as String? ?? '');
    if (tag == null || version == null || url == null || !url.hasScheme) {
      return null;
    }
    return GithubVersionCandidate(
      version: version,
      tag: tag,
      url: url,
      source: VendorVersionSource.githubRelease,
      checkedAt: _now(),
    );
  }

  Future<GithubVersionCandidate?> _latestTag(
    GithubPortSource source,
    VcpkgVersionScheme scheme,
  ) async {
    final GithubHttpResponse response = await transport.get(
      Uri.https(
        'api.github.com',
        '/repos/${source.repository}/tags',
        <String, String>{'per_page': '100'},
      ),
    );
    _ensureSuccessful(response, source.repository);
    final Object? decoded = _decodeJson(response.body);
    if (decoded is! List) {
      throw const GithubVendorApiException(
        'GitHub tags response is not a JSON array.',
      );
    }
    String? latestVersion;
    String? latestTag;
    for (final Object? item in decoded) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      final String? tag = item['name'] as String?;
      final String? version = tag == null ? null : source.versionFromTag(tag);
      if (version == null || !comparator.isStable(version, scheme)) {
        continue;
      }
      final int? comparison = latestVersion == null
          ? null
          : comparator.compare(latestVersion, version, scheme);
      if (latestVersion == null || (comparison != null && comparison < 0)) {
        latestVersion = version;
        latestTag = tag;
      }
    }
    if (latestVersion == null || latestTag == null) {
      return null;
    }
    return GithubVersionCandidate(
      version: latestVersion,
      tag: latestTag,
      url: Uri.parse(
        'https://github.com/${source.repository}/tree/'
        '${Uri.encodeComponent(latestTag)}',
      ),
      source: VendorVersionSource.githubTag,
      checkedAt: _now(),
    );
  }

  void _ensureSuccessful(GithubHttpResponse response, String repository) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    if (response.statusCode == HttpStatus.tooManyRequests ||
        (response.statusCode == HttpStatus.forbidden &&
            (response.rateLimitRemaining == '0' ||
                response.body.toLowerCase().contains('rate limit')))) {
      throw const GithubRateLimitException(
        'GitHub API rate limit was reached. Try again later or set '
        'GITHUB_TOKEN.',
      );
    }
    throw GithubVendorApiException(
      'GitHub API returned HTTP ${response.statusCode} for $repository.',
    );
  }

  Object? _decodeJson(String body) {
    try {
      return jsonDecode(body);
    } on FormatException catch (error) {
      throw GithubVendorApiException(
        'GitHub returned invalid JSON: ${error.message}',
      );
    }
  }
}
