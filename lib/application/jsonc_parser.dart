import 'dart:convert';

Object? decodeJsonc(String source) => jsonDecode(stripJsonComments(source));

String stripJsonComments(String source) {
  final StringBuffer result = StringBuffer();
  var inString = false;
  var escaped = false;

  for (var index = 0; index < source.length; index++) {
    final String character = source[index];
    if (inString) {
      result.write(character);
      if (escaped) {
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
      } else if (character == '"') {
        inString = false;
      }
      continue;
    }

    if (character == '"') {
      inString = true;
      result.write(character);
      continue;
    }

    if (character != '/' || index + 1 >= source.length) {
      result.write(character);
      continue;
    }

    final String next = source[index + 1];
    if (next == '/') {
      result.write('  ');
      index += 2;
      while (index < source.length &&
          source[index] != '\n' &&
          source[index] != '\r') {
        result.write(' ');
        index++;
      }
      if (index < source.length) {
        result.write(source[index]);
      }
      continue;
    }

    if (next == '*') {
      result.write('  ');
      index += 2;
      var closed = false;
      while (index < source.length) {
        if (source[index] == '*' &&
            index + 1 < source.length &&
            source[index + 1] == '/') {
          result.write('  ');
          index++;
          closed = true;
          break;
        }
        final String commentCharacter = source[index];
        result.write(
          commentCharacter == '\n' || commentCharacter == '\r'
              ? commentCharacter
              : ' ',
        );
        index++;
      }
      if (!closed) {
        throw const FormatException('Unterminated JSONC block comment.');
      }
      continue;
    }

    result.write(character);
  }

  return result.toString();
}
