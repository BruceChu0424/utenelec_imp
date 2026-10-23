import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_history.dart';

String _original() => const JsonEncoder.withIndent('  ').convert(
  FormDraft(
    id: 'one',
    title: '原文',
    module: BadgeModule.sales,
    route: '/sales/orders/new',
    permission: 'sales_order:create',
    updatedAt: DateTime.utc(2026, 10),
    revision: 'r1',
    data: {'qty': '1.', 'text': '汉字😀\\"', 'bytes': 'QUJD' * 262144},
  ).toJson(),
);

void main() {
  test(
    'prepared history matches legacy decisions and retains exact originals',
    () async {
      final original = _original();
      final values = <String?>[
        null,
        original,
        '{',
        'null',
        '[]',
        'plain text',
        '{"version":99,"data":{"private":"kept"}}',
        '{"version":1,"id":"one","completed":true,"revision":"r2"}',
        '{"version":1,"id":"one","completed":true,"historyAction":"deleted"}',
      ];
      final prepared = <String?, PreparedFormDraftHistoryValue>{};
      for (final value in values) {
        final parsed = await prepareFormDraftHistoryValue(value);
        prepared[value] = parsed;
        expect(parsed.raw, value);
        expect(parsed.terminal, isFormDraftTerminalMarker(value));
        expect(parsed.compact, compactFormDraftTerminalMarker(value));
        expect(
          parsed.draft?.toJson(),
          decodeFormDraftHistoryPayload(value)?.toJson(),
        );
      }
      for (final existing in values) {
        for (final next in values) {
          for (final importing in [false, true]) {
            final oracle = formDraftHistoryChange(
              'scope_one',
              existing,
              next,
              importing: importing,
            );
            final actual = preparedFormDraftHistoryChange(
              'scope_one',
              prepared[existing]!,
              prepared[next]!,
              importing: importing,
            );
            expect(actual?.action, oracle?.action);
            expect(actual?.payload, oracle?.payload);
            expect(actual?.draft.toJson(), oracle?.draft.toJson());
          }
        }
      }
    },
  );
}
