import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vcpkg_ui/application/vcpkg_version_comparator.dart';
import 'package:vcpkg_ui/application/vendor_version_config.dart';
import 'package:vcpkg_ui/domain/vendor_version_models.dart';
import 'package:vcpkg_ui/infrastructure/vendor/vendor_version_cache.dart';

final class ConfiguredVendorVersionNotFoundException implements Exception {
  const ConfiguredVendorVersionNotFoundException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class ConfiguredVendorRateLimitException implements Exception {
  const ConfiguredVendorRateLimitException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class ConfiguredVendorApiException implements Exception {
  const ConfiguredVendorApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class ConfiguredVendorVersionCandidate {
  const ConfiguredVendorVersionCandidate({
    required this.version,
    required this.reference,
    required this.url,
    required this.source,
    required this.checkedAt,
    this.comparisonLocalVersion,
    this.fromCache = false,
  });

  final String version;
  final String reference;
  final Uri url;
  final VendorVersionSource source;
  final DateTime checkedAt;
  final String? comparisonLocalVersion;
  final bool fromCache;
}

final class VendorHttpResponse {
  const VendorHttpResponse({
    required this.statusCode,
    required this.body,
    this.rateLimitRemaining,
  });

  final int statusCode;
  final String body;
  final String? rateLimitRemaining;
}

abstract interface class VendorHttpTransport {
  Future<VendorHttpResponse> get(Uri uri);
}

final class IoVendorHttpTransport implements VendorHttpTransport {
  IoVendorHttpTransport({
    this.environment = const <String, String>{},
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient();

  static const Duration _requestTimeout = Duration(seconds: 20);
  static const int _maximumBodyBytes = 2 * 1024 * 1024;

  final Map<String, String> environment;
  final HttpClient _httpClient;

  @override
  Future<VendorHttpResponse> get(Uri uri) async {
    final HttpClientRequest request = await _httpClient
        .getUrl(uri)
        .timeout(_requestTimeout);
    request.headers.set(HttpHeaders.userAgentHeader, 'vcpkg-ui');
    if (uri.host.toLowerCase() == 'api.github.com') {
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final String? token = environment['GITHUB_TOKEN']?.trim();
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
    } else {
      request.headers.set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml',
      );
    }
    final HttpClientResponse response = await request.close().timeout(
      _requestTimeout,
    );
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(_requestTimeout)) {
      if (bytes.length + chunk.length > _maximumBodyBytes) {
        throw ConfiguredVendorApiException(
          'Response from ${uri.host} exceeded 2 MiB.',
        );
      }
      bytes.add(chunk);
    }
    return VendorHttpResponse(
      statusCode: response.statusCode,
      body: utf8.decode(bytes.takeBytes(), allowMalformed: true),
      rateLimitRemaining: response.headers.value('x-ratelimit-remaining'),
    );
  }
}

abstract interface class ConfiguredVendorVersionClient {
  Future<ConfiguredVendorVersionCandidate> findLatest(
    VendorVersionRule rule,
    VcpkgVersionScheme fallbackScheme,
  );
}

final class ConfiguredVendorApi implements ConfiguredVendorVersionClient {
  ConfiguredVendorApi({
    required this.cache,
    Map<String, String> environment = const <String, String>{},
    VendorHttpTransport? transport,
    this.comparator = const VcpkgVersionComparator(),
    DateTime Function()? now,
  }) : transport = transport ?? IoVendorHttpTransport(environment: environment),
       _now = now ?? DateTime.now;

  final VendorVersionCache cache;
  final VendorHttpTransport transport;
  final VcpkgVersionComparator comparator;
  final DateTime Function() _now;

  @override
  Future<ConfiguredVendorVersionCandidate> findLatest(
    VendorVersionRule rule,
    VcpkgVersionScheme fallbackScheme,
  ) async {
    final VcpkgVersionScheme scheme = rule.comparisonScheme ?? fallbackScheme;
    final String cacheKey = 'configured|${rule.fingerprint}|${scheme.name}';
    final CachedVendorVersion? cached = await cache.read(cacheKey);
    if (cached != null) {
      return ConfiguredVendorVersionCandidate(
        version: cached.version,
        reference: cached.tag,
        url: cached.url,
        source: cached.source,
        checkedAt: cached.checkedAt,
        comparisonLocalVersion: cached.comparisonLocalVersion,
        fromCache: true,
      );
    }

    final ConfiguredVendorVersionCandidate candidate = await (switch (rule) {
      GithubTagsVendorVersionRule() => _githubTags(rule, scheme),
      HttpIndexVendorVersionRule() => _httpIndex(rule, scheme),
      GithubCommitDateVendorVersionRule() => _githubCommitDate(rule),
      DisabledVendorVersionRule() || InvalidVendorVersionRule() =>
        throw StateError('${rule.provider} rules cannot be queried.'),
    });
    await cache.write(
      cacheKey,
      CachedVendorVersion(
        version: candidate.version,
        tag: candidate.reference,
        url: candidate.url,
        source: candidate.source,
        checkedAt: candidate.checkedAt,
        comparisonLocalVersion: candidate.comparisonLocalVersion,
      ),
    );
    return candidate;
  }

  Future<ConfiguredVendorVersionCandidate> _githubTags(
    GithubTagsVendorVersionRule rule,
    VcpkgVersionScheme scheme,
  ) async {
    final bool matchingRefs = rule.tagPrefix.isNotEmpty;
    final Uri uri = matchingRefs
        ? Uri.https(
            'api.github.com',
            '/repos/${rule.githubRepository}/git/matching-refs/tags/'
                '${rule.tagPrefix}',
          )
        : Uri.https(
            'api.github.com',
            '/repos/${rule.githubRepository}/tags',
            const <String, String>{'per_page': '100'},
          );
    final VendorHttpResponse response = await transport.get(uri);
    _ensureGithubSuccessful(response, rule.githubRepository);
    final Object? decoded = _decodeJson(response.body, 'GitHub tags');
    if (decoded is! List) {
      throw const ConfiguredVendorApiException(
        'GitHub tags response is not a JSON array.',
      );
    }

    String? latestVersion;
    String? latestTag;
    for (final Object? item in decoded) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      final String? tag = matchingRefs
          ? _tagFromReference(item['ref'] as String?)
          : item['name'] as String?;
      if (tag == null) {
        continue;
      }
      final RegExpMatch? match = rule.matcher.firstMatch(tag);
      if (match == null || match.group(0) != tag) {
        continue;
      }
      final String rawVersion = match.namedGroup('version')!;
      final String version = rule.transformVendorVersion(rawVersion);
      if (!comparator.isStable(version, scheme)) {
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
      throw ConfiguredVendorVersionNotFoundException(
        'No stable GitHub tag matched ${rule.tagRegex}.',
      );
    }
    return ConfiguredVendorVersionCandidate(
      version: latestVersion,
      reference: latestTag,
      url: Uri.parse(
        'https://github.com/${rule.githubRepository}/tree/'
        '${Uri.encodeComponent(latestTag)}',
      ),
      source: VendorVersionSource.githubTag,
      checkedAt: _now(),
    );
  }

  Future<ConfiguredVendorVersionCandidate> _githubCommitDate(
    GithubCommitDateVendorVersionRule rule,
  ) async {
    final List<VendorHttpResponse> responses =
        await Future.wait(<Future<VendorHttpResponse>>[
          transport.get(
            Uri.https(
              'api.github.com',
              '/repos/${rule.githubRepository}/commits/${rule.localCommit}',
            ),
          ),
          transport.get(
            Uri.https(
              'api.github.com',
              '/repos/${rule.githubRepository}/commits/${rule.branch}',
            ),
          ),
        ]);
    _ensureGithubSuccessful(responses[0], rule.githubRepository);
    _ensureGithubSuccessful(responses[1], rule.githubRepository);
    final _GithubCommit local = _decodeCommit(
      responses[0].body,
      rule.localCommit,
    );
    final _GithubCommit latest = _decodeCommit(responses[1].body, rule.branch);
    return ConfiguredVendorVersionCandidate(
      version: _dateVersion(latest.committedAt),
      reference: latest.sha,
      url: latest.url,
      source: VendorVersionSource.githubCommit,
      checkedAt: _now(),
      comparisonLocalVersion: _dateVersion(local.committedAt),
    );
  }

  Future<ConfiguredVendorVersionCandidate> _httpIndex(
    HttpIndexVendorVersionRule rule,
    VcpkgVersionScheme scheme,
  ) async {
    String? latestVersion;
    String? latestEntry;
    Uri? latestUrl;
    final List<String> failures = <String>[];
    var successfulResponses = 0;

    for (final Uri indexUrl in rule.indexUrls) {
      try {
        final VendorHttpResponse response = await transport.get(indexUrl);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          failures.add('${indexUrl.host}: HTTP ${response.statusCode}');
          continue;
        }
        successfulResponses++;
        for (final String href in _htmlLinks(response.body)) {
          final Uri? resolved = _safeDirectChild(indexUrl, href);
          if (resolved == null) {
            continue;
          }
          final String entry = _directChildName(indexUrl, resolved);
          final RegExpMatch? match = rule.matcher.firstMatch(entry);
          if (match == null || match.group(0) != entry) {
            continue;
          }
          final String version = rule.transformVendorVersion(
            match.namedGroup('version')!,
          );
          if (!comparator.isStable(version, scheme)) {
            continue;
          }
          final int? comparison = latestVersion == null
              ? null
              : comparator.compare(latestVersion, version, scheme);
          if (latestVersion == null || (comparison != null && comparison < 0)) {
            latestVersion = version;
            latestEntry = entry;
            latestUrl = resolved;
          }
        }
      } on Object catch (error) {
        failures.add('${indexUrl.host}: $error');
      }
    }

    if (latestVersion == null || latestEntry == null || latestUrl == null) {
      if (successfulResponses == 0 && failures.isNotEmpty) {
        throw ConfiguredVendorApiException(
          'Could not read configured version index: ${failures.join('; ')}',
        );
      }
      throw ConfiguredVendorVersionNotFoundException(
        'No stable index entry matched ${rule.entryRegex}.',
      );
    }
    return ConfiguredVendorVersionCandidate(
      version: latestVersion,
      reference: latestEntry,
      url: latestUrl,
      source: VendorVersionSource.httpIndex,
      checkedAt: _now(),
    );
  }

  String? _tagFromReference(String? reference) {
    const String prefix = 'refs/tags/';
    return reference != null && reference.startsWith(prefix)
        ? reference.substring(prefix.length)
        : null;
  }

  void _ensureGithubSuccessful(VendorHttpResponse response, String repository) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    if (response.statusCode == HttpStatus.tooManyRequests ||
        (response.statusCode == HttpStatus.forbidden &&
            (response.rateLimitRemaining == '0' ||
                response.body.toLowerCase().contains('rate limit')))) {
      throw const ConfiguredVendorRateLimitException(
        'GitHub API rate limit was reached. Try again later or set '
        'GITHUB_TOKEN.',
      );
    }
    throw ConfiguredVendorApiException(
      'GitHub API returned HTTP ${response.statusCode} for $repository.',
    );
  }

  Object? _decodeJson(String body, String label) {
    try {
      return jsonDecode(body);
    } on FormatException catch (error) {
      throw ConfiguredVendorApiException(
        '$label returned invalid JSON: ${error.message}',
      );
    }
  }

  _GithubCommit _decodeCommit(String body, String reference) {
    final Object? decoded = _decodeJson(body, 'GitHub commit');
    if (decoded is! Map<String, dynamic>) {
      throw ConfiguredVendorApiException(
        'GitHub commit response is invalid for $reference.',
      );
    }
    final Object? rawCommit = decoded['commit'];
    final Object? rawCommitter = rawCommit is Map<String, dynamic>
        ? rawCommit['committer']
        : null;
    final String? dateText = rawCommitter is Map<String, dynamic>
        ? rawCommitter['date'] as String?
        : null;
    final DateTime? committedAt = dateText == null
        ? null
        : DateTime.tryParse(dateText);
    final String? sha = decoded['sha'] as String?;
    final Uri? url = Uri.tryParse(decoded['html_url'] as String? ?? '');
    if (sha == null || committedAt == null || url == null || !url.hasScheme) {
      throw ConfiguredVendorApiException(
        'GitHub commit response is missing fields for $reference.',
      );
    }
    return _GithubCommit(sha: sha, url: url, committedAt: committedAt);
  }

  String _dateVersion(DateTime value) {
    final DateTime utc = value.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }

  Iterable<String> _htmlLinks(String html) sync* {
    final RegExp pattern = RegExp(
      r'''\bhref\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    );
    for (final RegExpMatch match in pattern.allMatches(html)) {
      yield _decodeHtml(match.group(1)!);
    }
  }

  String _decodeHtml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  Uri? _safeDirectChild(Uri indexUrl, String href) {
    final Uri? reference = Uri.tryParse(href);
    if (reference == null) {
      return null;
    }
    final Uri resolved = indexUrl.resolveUri(reference);
    if (resolved.scheme != indexUrl.scheme || resolved.host != indexUrl.host) {
      return null;
    }
    final String basePath = indexUrl.path.endsWith('/')
        ? indexUrl.path
        : '${indexUrl.path}/';
    if (!resolved.path.startsWith(basePath)) {
      return null;
    }
    final String remainder = resolved.path.substring(basePath.length);
    final String withoutTrailingSlash = remainder.endsWith('/')
        ? remainder.substring(0, remainder.length - 1)
        : remainder;
    return withoutTrailingSlash.isNotEmpty &&
            !withoutTrailingSlash.contains('/')
        ? resolved
        : null;
  }

  String _directChildName(Uri indexUrl, Uri child) {
    final String basePath = indexUrl.path.endsWith('/')
        ? indexUrl.path
        : '${indexUrl.path}/';
    final String relative = child.path.substring(basePath.length);
    return Uri.decodeComponent(relative);
  }
}

final class _GithubCommit {
  const _GithubCommit({
    required this.sha,
    required this.url,
    required this.committedAt,
  });

  final String sha;
  final Uri url;
  final DateTime committedAt;
}
