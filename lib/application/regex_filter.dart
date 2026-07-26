class RegexFilterResult<T> {
  const RegexFilterResult({required this.items, this.error});

  final List<T> items;
  final String? error;

  bool get isValid => error == null;
}

RegexFilterResult<T> filterByRegex<T>(
  Iterable<T> source,
  String pattern,
  String Function(T item) valueOf,
) {
  if (pattern.isEmpty) {
    return RegexFilterResult<T>(items: List<T>.unmodifiable(source));
  }

  late final RegExp expression;
  try {
    expression = RegExp(pattern, caseSensitive: false);
  } on FormatException catch (error) {
    return RegexFilterResult<T>(items: const [], error: error.message);
  }

  return RegexFilterResult<T>(
    items: List<T>.unmodifiable(
      source.where((item) => expression.hasMatch(valueOf(item))),
    ),
  );
}
