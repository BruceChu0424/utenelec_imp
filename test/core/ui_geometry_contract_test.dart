@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Adoption guard: feature code must not quietly reintroduce the independent
/// modal geometry and literal surface radii retired by the platform UI change.
void main() {
  test('all modal constructors use the constrained platform shells', () {
    final violations = <String>[];
    final constructors = RegExp(
      r'\b(AlertDialog|Dialog|SimpleDialog)(?:\.([A-Za-z_]\w*))?\s*\(',
    );
    for (final entry in _sources()) {
      if (entry.path == 'lib/components/feedback/uten_dialog.dart') continue;
      for (final match in constructors.allMatches(entry.code)) {
        if (match.group(1) == 'Dialog' && match.group(2) == 'fullscreen') {
          continue;
        }
        violations.add(
          '${entry.path}:${_line(entry.code, match.start)} ${match.group(0)}',
        );
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'Use UtenAlertDialog/UtenDialogFrame so local width, keyboard, zoom and short-window behavior stay shared.',
    );
  });

  test('surface corner radii use shared design roles', () {
    final violations = <String>[];
    final literalRadius = RegExp(r'\b(?:BorderRadius|Radius)\.circular\(\s*\d');
    for (final entry in _sources()) {
      for (final match in literalRadius.allMatches(entry.code)) {
        violations.add('${entry.path}:${_line(entry.code, match.start)}');
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'Use UtenRadius roles; data geometry and layout dimensions are separate from UI surface corners.',
    );
  });
}

Iterable<({String path, String code})> _sources() sync* {
  final stringsAndComments = RegExp(
    r"""//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'""",
  );
  for (final file in Directory(
    'lib',
  ).listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    final source = file.readAsStringSync();
    final code = source.replaceAllMapped(
      stringsAndComments,
      (match) => match.group(0)!.replaceAll(RegExp(r'[^\n]'), ' '),
    );
    yield (path: file.path.replaceAll('\\', '/'), code: code);
  }
}

int _line(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;
