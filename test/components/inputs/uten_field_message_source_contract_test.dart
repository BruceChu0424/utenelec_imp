import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all lib form messages use the shared disclosure contract', () {
    final violations = <String>[];
    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    final rawMessagePattern = RegExp(r'\b(?:helperText|errorText)\s*:');
    final textFormPattern = RegExp(r'\bTextFormField\s*\(');
    final sharedBuilderPattern = RegExp(
      r'\berrorBuilder\s*:\s*utenTextFieldErrorBuilder\b',
    );
    final rawExceptionPattern = RegExp(
      r'//\s*uten-field-message-exception:\s*raw-message\b',
    );
    final textFormExceptionPattern = RegExp(
      r'//\s*uten-field-message-exception:\s*TextFormField\b',
    );

    for (final file in dartFiles) {
      final source = file.readAsStringSync();
      final rawCount = rawMessagePattern.allMatches(source).length;
      final rawExceptions = rawExceptionPattern.allMatches(source).length;
      if (rawCount != rawExceptions) {
        violations.add(
          '${file.path}: raw helperText/errorText=$rawCount, '
          'annotated exceptions=$rawExceptions',
        );
      }

      final textFormCount = textFormPattern.allMatches(source).length;
      if (textFormCount == 0) continue;
      final sharedBuilderCount = sharedBuilderPattern.allMatches(source).length;
      final textFormExceptions = textFormExceptionPattern
          .allMatches(source)
          .length;
      if (textFormCount != sharedBuilderCount + textFormExceptions) {
        violations.add(
          '${file.path}: TextFormField=$textFormCount, '
          'shared errorBuilder=$sharedBuilderCount, '
          'annotated exceptions=$textFormExceptions',
        );
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Use InputDecoration.helper/error with UtenFieldMessage and add '
          'errorBuilder: utenTextFieldErrorBuilder to direct TextFormField. '
          'A genuine exception must carry an adjacent '
          '// uten-field-message-exception: <kind> - <reason> comment.\n'
          '${violations.join('\n')}',
    );
  });
}
