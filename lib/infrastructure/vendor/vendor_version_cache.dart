import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:vcpkg_ui/domain/vendor_version_models.dart';

final class CachedVendorVersion {
  const CachedVendorVersion({
    required this.version,
    required this.tag,
    required this.url,
    required this.source,
    required this.checkedAt,
    this.comparisonLocalVersion,
  });

  final String version;
  final String tag;
  final Uri url;
  final VendorVersionSource source;
  final DateTime checkedAt;
  final String? comparisonLocalVersion;
}

final class VendorVersionCache {
  VendorVersionCache({
    required String filePath,
    this.timeToLive = const Duration(hours: 24),
    DateTime Function()? now,
  }) : _file = File(filePath),
       _now = now ?? DateTime.now;

  final File _file;
  final Duration timeToLive;
  final DateTime Function() _now;

  Map<String, CachedVendorVersion>? _entries;
  Future<void>? _loadFuture;
  Future<void> _writeTail = Future<void>.value();

  Future<CachedVendorVersion?> read(String key) async {
    await _ensureLoaded();
    final CachedVendorVersion? value = _entries![key];
    if (value == null || _now().difference(value.checkedAt) > timeToLive) {
      return null;
    }
    return value;
  }

  Future<void> write(String key, CachedVendorVersion value) async {
    await _ensureLoaded();
    _entries![key] = value;
    final Future<void> operation = _writeTail.then((_) => _persist());
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await operation;
  }

  Future<void> _persist() async {
    await _file.parent.create(recursive: true);
    final Map<String, Object?> encoded = <String, Object?>{
      'schema': 2,
      'entries': <String, Object?>{
        for (final MapEntry<String, CachedVendorVersion> entry
            in _entries!.entries)
          entry.key: <String, Object?>{
            'version': entry.value.version,
            'tag': entry.value.tag,
            'url': entry.value.url.toString(),
            'source': entry.value.source.name,
            'checkedAt': entry.value.checkedAt.toUtc().toIso8601String(),
            if (entry.value.comparisonLocalVersion != null)
              'comparisonLocalVersion': entry.value.comparisonLocalVersion,
          },
      },
    };
    await _file.writeAsString(jsonEncode(encoded), flush: true);
  }

  Future<void> _ensureLoaded() async {
    if (_entries != null) {
      return;
    }
    await (_loadFuture ??= _load());
  }

  Future<void> _load() async {
    final Map<String, CachedVendorVersion> result =
        <String, CachedVendorVersion>{};
    try {
      if (!await _file.exists()) {
        _entries = result;
        return;
      }
      final Object? decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          (decoded['schema'] != 1 && decoded['schema'] != 2)) {
        _entries = result;
        return;
      }
      final Object? rawEntries = decoded['entries'];
      if (rawEntries is! Map<String, dynamic>) {
        _entries = result;
        return;
      }
      for (final MapEntry<String, dynamic> entry in rawEntries.entries) {
        final Object? rawValue = entry.value;
        if (rawValue is! Map<String, dynamic>) {
          continue;
        }
        final String? version = rawValue['version'] as String?;
        final String? tag = rawValue['tag'] as String?;
        final Uri? url = Uri.tryParse(rawValue['url'] as String? ?? '');
        final DateTime? checkedAt = DateTime.tryParse(
          rawValue['checkedAt'] as String? ?? '',
        );
        VendorVersionSource? source;
        for (final VendorVersionSource candidate
            in VendorVersionSource.values) {
          if (candidate.name == rawValue['source']) {
            source = candidate;
            break;
          }
        }
        if (version == null ||
            tag == null ||
            url == null ||
            !url.hasScheme ||
            checkedAt == null ||
            source == null) {
          continue;
        }
        result[entry.key] = CachedVendorVersion(
          version: version,
          tag: tag,
          url: url,
          source: source,
          checkedAt: checkedAt.toLocal(),
          comparisonLocalVersion: rawValue['comparisonLocalVersion'] as String?,
        );
      }
    } on Object {
      // A cache is disposable. Corruption must never block catalog startup or
      // a fresh vendor-version check.
    }
    _entries = result;
  }

  static String defaultFilePath(String applicationDataDirectory) =>
      path.join(applicationDataDirectory, 'cache', 'vendor-versions.json');
}
