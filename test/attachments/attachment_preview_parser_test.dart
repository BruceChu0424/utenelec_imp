import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/attachments/attachment_delimited_text.dart';
import 'package:uten_imp/shared/attachments/attachment_file_rules.dart';
import 'package:uten_imp/shared/attachments/attachment_preview_parser.dart';
import 'package:uten_imp/shared/attachments/attachment_text_decoder.dart';

void main() {
  test(
    'sliced decoding preserves BOM, split characters and malformed fallback',
    () async {
      final ascii = List.filled(16383, 0x61);
      final utf16Text = '${'a' * 8191}𠀀中文';
      final samples = [
        Uint8List(0),
        Uint8List.fromList([...ascii, ...utf8.encode('𠀀中文')]),
        Uint8List.fromList([0xEF, 0xBB, 0xBF, ...ascii, 0xFF]),
        Uint8List.fromList([...ascii, 0x95, 0x32, 0x82, 0x36, 0xD6, 0xD0]),
        Uint8List.fromList([...ascii, 0xFF, 0xE9, 0x80, 0x41]),
        Uint8List.fromList([
          0xFF,
          0xFE,
          for (final code in utf16Text.codeUnits) ...[code & 255, code >> 8],
          0x41,
        ]),
        Uint8List.fromList([
          0xFE,
          0xFF,
          for (final code in utf16Text.codeUnits) ...[code >> 8, code & 255],
        ]),
      ];
      for (final bytes in samples) {
        final expected = decodeAttachmentText(bytes);
        final actual = await decodeAttachmentTextInUiSlices(bytes);
        expect(actual.encoding, expected.encoding);
        expect(actual.text, expected.text);
      }
    },
  );

  test(
    'CSV slices preserve escaped quotes, multiline cells and exact truncated count',
    () async {
      final longCell = '${'甲' * 16382}," quoted\n第二行';
      final escaped = longCell.replaceAll('"', '""');
      final text = '名称;备注\r\n甲;"$escaped"\r\n${'乙;2\r\n' * 3000}丙;3';
      var turns = 0;
      final timer = Timer.periodic(Duration.zero, (_) => turns++);
      final table = await parseDelimitedTextInUiSlices(text);
      timer.cancel();
      expect(table.delimiter, ';');
      expect(table.rows[1], ['甲', longCell]);
      expect(table.rows, hasLength(1000));
      expect(table.totalRows, 3003);
      expect(table.truncated, isTrue);
      expect(
        turns,
        greaterThan(1),
        reason: 'event-loop timers must run during parsing',
      );
      final sync = parseDelimitedText(text);
      expect(table.rows, sync.rows);
      expect(table.totalRows, sync.totalRows);
    },
  );

  test(
    'large browser parse yields while decoding and can be superseded',
    () async {
      final bytes = Uint8List.fromList(
        utf8.encode('名称,数量\n${'物料,12\n' * 100000}'),
      );
      var current = true;
      var turns = 0;
      final timer = Timer.periodic(Duration.zero, (_) {
        if (++turns == 3) current = false;
      });
      await expectLater(
        parseAttachmentPreviewInUiSlices(
          AttachmentPreviewKind.csv,
          bytes,
          budget: UiWorkBudget(isCurrent: () => current),
        ),
        throwsA(isA<UiWorkCancelled>()),
      );
      timer.cancel();
      expect(turns, greaterThanOrEqualTo(3));
    },
  );

  test(
    'large native/browser entry point returns complete text and encoding',
    () async {
      final text = '中文𠀀\n' * 12000;
      final result = await parseAttachmentPreview(
        AttachmentPreviewKind.text,
        Uint8List.fromList(utf8.encode(text)),
      );
      expect(result.error, isNull);
      expect(result.text!.text, text);
      expect(result.text!.encoding, AttachmentTextEncoding.utf8);
    },
  );

  test('invalid archive remains a useful preview error', () async {
    final result = await parseAttachmentPreviewInUiSlices(
      AttachmentPreviewKind.archive,
      Uint8List.fromList([1, 2, 3]),
    );
    expect(result.error, contains('ZIP'));
  });
}
