import 'package:vcpkg_ui/domain/vendor_version_models.dart';

final class VcpkgVersionComparator {
  const VcpkgVersionComparator();

  /// Returns a negative value when [left] is older than [right], zero when
  /// equal, a positive value when newer, and null when comparison is unsafe.
  int? compare(String left, String right, VcpkgVersionScheme scheme) =>
      switch (scheme) {
        VcpkgVersionScheme.semver => _compareSemver(left, right),
        VcpkgVersionScheme.date => _compareDate(left, right),
        VcpkgVersionScheme.relaxed => _compareRelaxed(left, right),
        VcpkgVersionScheme.string => left == right ? 0 : null,
      };

  bool isStable(String value, VcpkgVersionScheme scheme) {
    switch (scheme) {
      case VcpkgVersionScheme.semver:
        final _Semver? version = _Semver.tryParse(value);
        return version != null && version.prerelease.isEmpty;
      case VcpkgVersionScheme.date:
        return _DateVersion.tryParse(value) != null;
      case VcpkgVersionScheme.relaxed:
        return _relaxedParts(value) != null;
      case VcpkgVersionScheme.string:
        return false;
    }
  }

  int? _compareSemver(String left, String right) {
    final _Semver? leftVersion = _Semver.tryParse(left);
    final _Semver? rightVersion = _Semver.tryParse(right);
    return leftVersion == null || rightVersion == null
        ? null
        : leftVersion.compareTo(rightVersion);
  }

  int? _compareDate(String left, String right) {
    final _DateVersion? leftVersion = _DateVersion.tryParse(left);
    final _DateVersion? rightVersion = _DateVersion.tryParse(right);
    return leftVersion == null || rightVersion == null
        ? null
        : leftVersion.compareTo(rightVersion);
  }

  int? _compareRelaxed(String left, String right) {
    final List<int>? leftParts = _relaxedParts(left);
    final List<int>? rightParts = _relaxedParts(right);
    if (leftParts == null || rightParts == null) {
      return null;
    }
    final int length = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var index = 0; index < length; index++) {
      final int leftPart = index < leftParts.length ? leftParts[index] : 0;
      final int rightPart = index < rightParts.length ? rightParts[index] : 0;
      final int result = leftPart.compareTo(rightPart);
      if (result != 0) {
        return result;
      }
    }
    return 0;
  }

  List<int>? _relaxedParts(String value) {
    if (!RegExp(
      r'^(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))*$',
    ).hasMatch(value)) {
      return null;
    }
    return value.split('.').map(int.parse).toList(growable: false);
  }
}

final class _DateVersion implements Comparable<_DateVersion> {
  const _DateVersion(this.date, this.disambiguator);

  final DateTime date;
  final int disambiguator;

  static _DateVersion? tryParse(String value) {
    final RegExpMatch? match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})(?:\.(0|[1-9]\d*))?$',
    ).firstMatch(value);
    if (match == null) {
      return null;
    }
    final int year = int.parse(match.group(1)!);
    final int month = int.parse(match.group(2)!);
    final int day = int.parse(match.group(3)!);
    final DateTime date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return _DateVersion(date, int.parse(match.group(4) ?? '0'));
  }

  @override
  int compareTo(_DateVersion other) {
    final int dateResult = date.compareTo(other.date);
    return dateResult != 0
        ? dateResult
        : disambiguator.compareTo(other.disambiguator);
  }
}

final class _Semver implements Comparable<_Semver> {
  const _Semver({
    required this.major,
    required this.minor,
    required this.patch,
    required this.prerelease,
  });

  final int major;
  final int minor;
  final int patch;
  final List<String> prerelease;

  static _Semver? tryParse(String value) {
    final RegExpMatch? match = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
      r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
      r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
    ).firstMatch(value);
    if (match == null) {
      return null;
    }
    return _Semver(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      patch: int.parse(match.group(3)!),
      prerelease: match.group(4)?.split('.') ?? const <String>[],
    );
  }

  @override
  int compareTo(_Semver other) {
    for (final (int left, int right) in <(int, int)>[
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final int result = left.compareTo(right);
      if (result != 0) {
        return result;
      }
    }
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      return prerelease.isEmpty == other.prerelease.isEmpty
          ? 0
          : prerelease.isEmpty
          ? 1
          : -1;
    }
    final int length = prerelease.length > other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (var index = 0; index < length; index++) {
      if (index >= prerelease.length) {
        return -1;
      }
      if (index >= other.prerelease.length) {
        return 1;
      }
      final String left = prerelease[index];
      final String right = other.prerelease[index];
      final int? leftNumber = int.tryParse(left);
      final int? rightNumber = int.tryParse(right);
      final int result = switch ((leftNumber, rightNumber)) {
        (final int leftValue, final int rightValue) => leftValue.compareTo(
          rightValue,
        ),
        (int(), null) => -1,
        (null, int()) => 1,
        _ => left.compareTo(right),
      };
      if (result != 0) {
        return result;
      }
    }
    return 0;
  }
}
