import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/io/file_saver.dart';

void main() {
  group('sanitizeDownloadFilename', () {
    test('removes traversal and platform path separators', () {
      expect(
        sanitizeDownloadFilename(r'../../payroll\2026:07?.pdf'),
        '_.._payroll_2026_07_.pdf',
      );
    });

    test('uses a safe fallback for empty or dot-only names', () {
      expect(sanitizeDownloadFilename(' ... '), 'download');
      expect(sanitizeDownloadFilename('\u0000'), 'download');
    });

    test('keeps normal localized filenames intact', () {
      expect(sanitizeDownloadFilename('工资条 2026-07.pdf'), '工资条 2026-07.pdf');
    });
  });
}
