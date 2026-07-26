import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/domain/package_models.dart';

final class GithubPortSource {
  const GithubPortSource({
    required this.repository,
    required this.tagPrefix,
    required this.tagSuffix,
  });

  final String repository;
  final String tagPrefix;
  final String tagSuffix;

  String tagForVersion(String version) => '$tagPrefix$version$tagSuffix';

  String? versionFromTag(String tag) {
    if (!tag.startsWith(tagPrefix) || !tag.endsWith(tagSuffix)) {
      return null;
    }
    final int end = tag.length - tagSuffix.length;
    if (end < tagPrefix.length) {
      return null;
    }
    final String value = tag.substring(tagPrefix.length, end);
    return value.isEmpty ? null : value;
  }
}

final class HttpIndexPortSource {
  HttpIndexPortSource({
    required Iterable<Uri> indexUrls,
    required this.entryRegex,
  }) : indexUrls = List<Uri>.unmodifiable(indexUrls);

  final List<Uri> indexUrls;
  final String entryRegex;
}

final class PortUpstreamSourceResult {
  const PortUpstreamSourceResult.supported(this.source)
    : httpIndexSource = null,
      reason = null;

  const PortUpstreamSourceResult.httpIndex(this.httpIndexSource)
    : source = null,
      reason = null;

  const PortUpstreamSourceResult.unsupported(this.reason)
    : source = null,
      httpIndexSource = null;

  final GithubPortSource? source;
  final HttpIndexPortSource? httpIndexSource;
  final String? reason;

  bool get isSupported => source != null || httpIndexSource != null;
}

final class PortUpstreamSourceReader {
  const PortUpstreamSourceReader();

  Future<PortUpstreamSourceResult> read(PortMetadata metadata) async {
    final String manifestDirectory =
        FileSystemEntity.isDirectorySync(metadata.manifestPath)
        ? metadata.manifestPath
        : path.dirname(metadata.manifestPath);
    final File portfile = File(path.join(manifestDirectory, 'portfile.cmake'));
    if (!await portfile.exists()) {
      return const PortUpstreamSourceResult.unsupported(
        'portfile.cmake does not exist.',
      );
    }
    try {
      return parse(await portfile.readAsString());
    } on Object catch (error) {
      return PortUpstreamSourceResult.unsupported(
        'Could not read portfile.cmake: $error',
      );
    }
  }

  PortUpstreamSourceResult parse(String text) {
    final List<RegExpMatch> calls = RegExp(
      r'\bvcpkg_from_github\s*\(',
      caseSensitive: false,
    ).allMatches(text).toList(growable: false);
    if (calls.isEmpty) {
      return _parseDownloadDistfile(text);
    }
    if (calls.length != 1) {
      return PortUpstreamSourceResult.unsupported(
        'More than one vcpkg_from_github source was found.',
      );
    }

    final String? call = _extractCall(text, calls.single.end - 1);
    if (call == null) {
      return const PortUpstreamSourceResult.unsupported(
        'The vcpkg_from_github call could not be parsed.',
      );
    }
    final String? repository = _argument(call, 'REPO');
    if (repository == null ||
        !RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
      return const PortUpstreamSourceResult.unsupported(
        'REPO is not a static owner/repository value.',
      );
    }

    final String? ref = _argument(call, 'REF');
    if (ref == null) {
      return const PortUpstreamSourceResult.unsupported(
        'REF is missing from vcpkg_from_github.',
      );
    }
    const String versionToken = r'${VERSION}';
    if (ref.split(versionToken).length != 2) {
      return const PortUpstreamSourceResult.unsupported(
        r'REF must contain exactly one ${VERSION} token.',
      );
    }
    final int tokenIndex = ref.indexOf(versionToken);
    final String prefix = ref.substring(0, tokenIndex);
    final String suffix = ref.substring(tokenIndex + versionToken.length);
    final RegExp safeTagFragment = RegExp(r'^[A-Za-z0-9._/+~-]*$');
    if (!safeTagFragment.hasMatch(prefix) ||
        !safeTagFragment.hasMatch(suffix)) {
      return const PortUpstreamSourceResult.unsupported(
        'REF contains an unsupported dynamic expression.',
      );
    }

    return PortUpstreamSourceResult.supported(
      GithubPortSource(
        repository: repository.toLowerCase(),
        tagPrefix: prefix,
        tagSuffix: suffix,
      ),
    );
  }

  PortUpstreamSourceResult _parseDownloadDistfile(String text) {
    final List<RegExpMatch> calls = RegExp(
      r'\bvcpkg_download_distfile\s*\(',
      caseSensitive: false,
    ).allMatches(text).toList(growable: false);
    if (calls.isEmpty) {
      return const PortUpstreamSourceResult.unsupported(
        'No supported upstream source was found.',
      );
    }
    if (calls.length != 1) {
      return const PortUpstreamSourceResult.unsupported(
        'More than one vcpkg_download_distfile source was found.',
      );
    }
    final String? call = _extractCall(text, calls.single.end - 1);
    if (call == null) {
      return const PortUpstreamSourceResult.unsupported(
        'The vcpkg_download_distfile call could not be parsed.',
      );
    }
    final List<String> urls = _listArgument(call, 'URLS');
    if (urls.isEmpty) {
      return const PortUpstreamSourceResult.unsupported(
        'URLS is missing from vcpkg_download_distfile.',
      );
    }

    final List<HttpIndexPortSource> indexes = <HttpIndexPortSource>[];
    GithubPortSource? github;
    for (final String url in urls) {
      final _DownloadInference inference = _inferDownloadUrl(url);
      switch (inference) {
        case _GithubDownloadInference():
          final GithubPortSource candidate = inference.source;
          if (github != null &&
              (github.repository != candidate.repository ||
                  github.tagPrefix != candidate.tagPrefix ||
                  github.tagSuffix != candidate.tagSuffix)) {
            return const PortUpstreamSourceResult.unsupported(
              'Download URLs resolve to different GitHub release sources.',
            );
          }
          github = candidate;
        case _HttpIndexDownloadInference():
          indexes.add(inference.source);
        case _UnsupportedDownloadInference():
          continue;
      }
    }
    if (github != null) {
      return PortUpstreamSourceResult.supported(github);
    }
    if (indexes.isNotEmpty) {
      final String pattern = indexes.first.entryRegex;
      if (indexes.any(
        (HttpIndexPortSource item) => item.entryRegex != pattern,
      )) {
        return const PortUpstreamSourceResult.unsupported(
          'Download URLs use incompatible version patterns.',
        );
      }
      return PortUpstreamSourceResult.httpIndex(
        HttpIndexPortSource(
          indexUrls: indexes.expand(
            (HttpIndexPortSource item) => item.indexUrls,
          ),
          entryRegex: pattern,
        ),
      );
    }
    return const PortUpstreamSourceResult.unsupported(
      r'Download URL must be HTTPS and contain only ${VERSION} as a dynamic expression.',
    );
  }

  _DownloadInference _inferDownloadUrl(String template) {
    const String versionToken = r'${VERSION}';
    if (!template.startsWith('https://') || !template.contains(versionToken)) {
      return const _UnsupportedDownloadInference();
    }
    final String withoutVersion = template.replaceAll(versionToken, '');
    if (RegExp(r'\$\{[^}]+\}').hasMatch(withoutVersion)) {
      return const _UnsupportedDownloadInference();
    }

    final RegExpMatch? githubMatch = RegExp(
      r'^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)'
      r'/releases/download/([^/]+)/',
      caseSensitive: false,
    ).firstMatch(template);
    if (githubMatch != null) {
      final String tagTemplate = Uri.decodeComponent(githubMatch.group(2)!);
      if (tagTemplate.split(versionToken).length == 2) {
        final int index = tagTemplate.indexOf(versionToken);
        return _GithubDownloadInference(
          GithubPortSource(
            repository: githubMatch.group(1)!.toLowerCase(),
            tagPrefix: tagTemplate.substring(0, index),
            tagSuffix: tagTemplate.substring(index + versionToken.length),
          ),
        );
      }
    }

    const String marker = 'VCPKG_VERSION_MARKER';
    final Uri? marked = Uri.tryParse(template.replaceAll(versionToken, marker));
    if (marked == null || marked.scheme != 'https' || marked.host.isEmpty) {
      return const _UnsupportedDownloadInference();
    }
    final int dynamicSegmentIndex = marked.pathSegments.indexWhere(
      (String segment) => segment.contains(marker),
    );
    if (dynamicSegmentIndex < 0) {
      return const _UnsupportedDownloadInference();
    }
    final String segment = marked.pathSegments[dynamicSegmentIndex];
    if (segment.split(marker).length != 2) {
      return const _UnsupportedDownloadInference();
    }
    final int markerIndex = segment.indexOf(marker);
    final String prefix = segment.substring(0, markerIndex);
    final String suffix = segment.substring(markerIndex + marker.length);
    final bool isDirectory =
        dynamicSegmentIndex < marked.pathSegments.length - 1;
    final String entryRegex =
        '^${RegExp.escape(prefix)}'
        r'(?<version>[0-9]+(?:\.[0-9]+)+)'
        '${RegExp.escape(suffix)}${isDirectory ? '/' : ''}\$';
    final List<String> parentSegments = marked.pathSegments
        .take(dynamicSegmentIndex)
        .toList(growable: false);
    final Uri indexUrl = marked
        .replace(pathSegments: parentSegments, query: null, fragment: null)
        .replace(path: '/${parentSegments.join('/')}/');
    final List<Uri> indexUrls = <Uri>[indexUrl];
    if (indexUrl.host.toLowerCase() == 'archive.apache.org' &&
        indexUrl.path.startsWith('/dist/')) {
      indexUrls.insert(
        0,
        indexUrl.replace(
          host: 'downloads.apache.org',
          path: indexUrl.path.substring('/dist'.length),
        ),
      );
    }
    return _HttpIndexDownloadInference(
      HttpIndexPortSource(indexUrls: indexUrls, entryRegex: entryRegex),
    );
  }

  String? _extractCall(String text, int openingParenthesis) {
    var depth = 0;
    String? quote;
    var escaped = false;
    for (var index = openingParenthesis; index < text.length; index++) {
      final String character = text[index];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (character == '\\') {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (character == quote) {
          quote = null;
        }
        continue;
      }
      if (character == '"' || character == "'") {
        quote = character;
        continue;
      }
      if (character == '(') {
        depth++;
      } else if (character == ')') {
        depth--;
        if (depth == 0) {
          return text.substring(openingParenthesis + 1, index);
        }
      }
    }
    return null;
  }

  String? _argument(String call, String name) {
    final RegExp pattern = RegExp(
      '\\b$name\\s+(?:"([^"]+)"|\'([^\']+)\'|([^\\s\\)#]+))',
      caseSensitive: false,
    );
    final RegExpMatch? match = pattern.firstMatch(call);
    return match == null
        ? null
        : match.group(1) ?? match.group(2) ?? match.group(3);
  }

  List<String> _listArgument(String call, String name) {
    final List<String> tokens = _tokens(call);
    final int start = tokens.indexWhere(
      (String token) => token.toUpperCase() == name.toUpperCase(),
    );
    if (start < 0) {
      return const <String>[];
    }
    const Set<String> keywords = <String>{
      'FILENAME',
      'SHA512',
      'SKIP_SHA512',
      'ALWAYS_REDOWNLOAD',
      'HEADERS',
    };
    final List<String> values = <String>[];
    for (var index = start + 1; index < tokens.length; index++) {
      if (keywords.contains(tokens[index].toUpperCase())) {
        break;
      }
      values.add(tokens[index]);
    }
    return values;
  }

  List<String> _tokens(String call) {
    final List<String> result = <String>[];
    final StringBuffer token = StringBuffer();
    String? quote;
    var comment = false;

    void commit() {
      final String value = token.toString().trim();
      if (value.isNotEmpty) {
        result.add(value);
      }
      token.clear();
    }

    for (var index = 0; index < call.length; index++) {
      final String character = call[index];
      if (comment) {
        if (character == '\n' || character == '\r') {
          comment = false;
        }
        continue;
      }
      if (quote != null) {
        if (character == quote) {
          quote = null;
        } else {
          token.write(character);
        }
        continue;
      }
      if (character == '#') {
        commit();
        comment = true;
      } else if (character == '"' || character == "'") {
        quote = character;
      } else if (character.trim().isEmpty) {
        commit();
      } else {
        token.write(character);
      }
    }
    commit();
    return result;
  }
}

sealed class _DownloadInference {
  const _DownloadInference();
}

final class _GithubDownloadInference extends _DownloadInference {
  const _GithubDownloadInference(this.source);

  final GithubPortSource source;
}

final class _HttpIndexDownloadInference extends _DownloadInference {
  const _HttpIndexDownloadInference(this.source);

  final HttpIndexPortSource source;
}

final class _UnsupportedDownloadInference extends _DownloadInference {
  const _UnsupportedDownloadInference();
}
