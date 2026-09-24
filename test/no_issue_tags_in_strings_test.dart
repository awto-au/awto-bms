// Issue "Remove old internal #NN tags from Diagnostics / raw-log wording":
// no Dart string literal under lib/ may carry an internal issue tag like
// "#53". Tags stay allowed in comments (and test names); a user or log reader
// must never see them.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One string literal found by [stringLiterals]: its 1-based line and its
/// source text (interpolations included, nested literals reported on their
/// own too).
class Literal {
  const Literal(this.line, this.text);
  final int line;
  final String text;
}

/// A small Dart lexer: every string literal in [src], skipping `//`, `///`
/// and (nested) `/* */` comments. Handles raw, single/double, triple-quoted
/// strings and `${...}` interpolations that contain their own strings.
List<Literal> stringLiterals(String src) {
  final out = <Literal>[];
  final n = src.length;

  int lineAt(int pos) => '\n'.allMatches(src.substring(0, pos)).length + 1;

  bool startsWith(String s, int at) => src.startsWith(s, at);

  late int Function(int pos, int closeBrace) scanCode;

  // Scans a string literal starting at [pos] (at the optional `r`). Returns
  // the index just past its closing quote.
  int scanString(int pos) {
    final start = pos;
    var raw = false;
    if (src[pos] == 'r' || src[pos] == 'R') {
      raw = true;
      pos++;
    }
    final q = src[pos];
    final triple = startsWith('$q$q$q', pos);
    final close = triple ? '$q$q$q' : q;
    pos += close.length;
    while (pos < n) {
      if (startsWith(close, pos)) {
        pos += close.length;
        out.add(Literal(lineAt(start), src.substring(start, pos)));
        return pos;
      }
      final c = src[pos];
      if (!raw && c == r'\') {
        pos += 2;
        continue;
      }
      if (!raw && c == r'$' && pos + 1 < n && src[pos + 1] == '{') {
        pos = scanCode(pos + 2, 1);
        continue;
      }
      if (!triple && c == '\n') break; // unterminated: give up on this one
      pos++;
    }
    out.add(Literal(lineAt(start), src.substring(start, pos)));
    return pos;
  }

  // Scans code from [pos]. With [closeBrace] > 0 it stops just past the `}`
  // that closes an interpolation; otherwise it runs to the end of the file.
  scanCode = (int pos, int closeBrace) {
    var depth = closeBrace;
    while (pos < n) {
      final c = src[pos];
      if (startsWith('//', pos)) {
        final eol = src.indexOf('\n', pos);
        pos = eol < 0 ? n : eol + 1;
        continue;
      }
      if (startsWith('/*', pos)) {
        var nest = 1;
        pos += 2;
        while (pos < n && nest > 0) {
          if (startsWith('/*', pos)) {
            nest++;
            pos += 2;
          } else if (startsWith('*/', pos)) {
            nest--;
            pos += 2;
          } else {
            pos++;
          }
        }
        continue;
      }
      final isRawStart = (c == 'r' || c == 'R') &&
          pos + 1 < n &&
          (src[pos + 1] == "'" || src[pos + 1] == '"') &&
          (pos == 0 || !RegExp(r'[A-Za-z0-9_$]').hasMatch(src[pos - 1]));
      if (c == "'" || c == '"' || isRawStart) {
        pos = scanString(pos);
        continue;
      }
      if (closeBrace > 0) {
        if (c == '{') depth++;
        if (c == '}') {
          depth--;
          if (depth == 0) return pos + 1;
        }
      }
      pos++;
    }
    return pos;
  };

  scanCode(0, 0);
  return out;
}

/// An internal issue tag: `#` + digits, not part of an HTML entity (`&#39;`)
/// or an identifier, and not a colour hex (`#FF8800`, `#123abc`).
final issueTag = RegExp(r'(?<![&\w])#\d+(?![0-9A-Fa-f])');

void main() {
  group('the lexer', () {
    test('finds literals and skips comments', () {
      const src = '''
// '#53 in a line comment'
/// '#53 in a doc comment'
/* '#53' /* nested '#53' */ still comment '#53' */
final a = 'plain #62 tag';
final b = "x \${c ? 'inner #41' : "y"} z";
final d = r'raw \\ #9';
final e = \'\'\'triple
#77 across lines\'\'\';
''';
      final lits = stringLiterals(src).map((l) => l.text).toList();
      expect(lits.any((t) => t.contains('comment')), isFalse);
      expect(lits, contains("'plain #62 tag'"));
      expect(lits, contains("'inner #41'"));
      expect(lits, contains(r"r'raw \ #9'"));
      expect(lits.any((t) => t.contains('#77 across lines')), isTrue);
      expect(lits.where((t) => t.contains('#53')), isEmpty);
    });

    test('the tag pattern ignores colours and HTML entities', () {
      expect(issueTag.hasMatch('#53 sample'), isTrue);
      expect(issueTag.hasMatch('probe (#62)'), isTrue);
      expect(issueTag.hasMatch('#FF8800'), isFalse);
      expect(issueTag.hasMatch('#1a2b3c'), isFalse);
      expect(issueTag.hasMatch('it&#39;s'), isFalse);
    });
  });

  test('no string literal under lib/ carries an internal #NN issue tag', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    final hits = <String>[];
    for (final f in files) {
      for (final lit in stringLiterals(f.readAsStringSync())) {
        if (issueTag.hasMatch(lit.text)) {
          hits.add('${f.path}:${lit.line}: ${lit.text}');
        }
      }
    }
    expect(hits, isEmpty,
        reason: 'user-visible text and log lines must use plain wording, '
            'not internal issue numbers');
  });
}
