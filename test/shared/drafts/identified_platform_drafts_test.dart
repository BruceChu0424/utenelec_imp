import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';
import 'package:uten_imp/shared/drafts/identified_platform_drafts.dart';
import 'package:uten_imp/shared/platform_tables/platform_row_draft.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_row.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

const field = PlatformColumnDefinition(
  id: 'ref',
  scope: 'production_daily_report_item',
  name: '批号',
);

void main() {
  test(
    'independent local IDs survive identical goods and source; clone gets a new identity',
    () {
      final first = DailyGridRow()
        ..goods = const GoodsOption(id: 'same-goods')
        ..executionSegmentId = 'same-segment';
      final second = first.clone();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      expect(second.localRowId, isNot(first.localRowId));
      first.platformFields.setValue(field, 'FIRST');
      second.platformFields.setValue(field, 'SECOND');
      final snapshot = captureIdentifiedPlatformDrafts([
        IdentifiedPlatformDraftRow(first.localRowId, first.platformFields),
        IdentifiedPlatformDraftRow(second.localRowId, second.platformFields),
      ]);
      final a = DailyGridRow(localRowId: first.localRowId);
      final b = DailyGridRow(localRowId: second.localRowId);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      restoreIdentifiedPlatformDrafts(snapshot, [
        IdentifiedPlatformDraftRow(b.localRowId, b.platformFields),
        IdentifiedPlatformDraftRow(a.localRowId, a.platformFields),
      ]);
      expect(a.platformFields.cells.single.value, 'FIRST');
      expect(b.platformFields.cells.single.value, 'SECOND');
      expect(platformRowPayload(a).toString(), contains('FIRST'));
      expect(platformRowPayload(a).toString(), isNot(contains(a.localRowId)));
    },
  );

  test(
    'legacy empty metadata ignores visible row count and never restores old source IDs',
    () {
      final empty = PlatformRowDraft()..sourceRecordId = 'unproven-old-id';
      final target = PlatformRowDraft();
      addTearDown(empty.dispose);
      addTearDown(target.dispose);
      restoreIdentifiedPlatformDrafts(
        [
          [empty.exportDraft(), empty.exportDraft()],
        ],
        [IdentifiedPlatformDraftRow('new-local', target)],
      );
      expect(target.cells, isEmpty);
      expect(target.sourceRecordId, isNull);
    },
  );

  for (final input in ['VALUE', '0', '', null]) {
    test(
      'legacy meaningful value or explicit clear is preserved, never guessed: $input',
      () {
        final legacy = PlatformRowDraft()..setValue(field, input);
        final target = PlatformRowDraft();
        addTearDown(legacy.dispose);
        addTearDown(target.dispose);
        final snapshot = [
          [legacy.exportDraft()],
        ];
        expect(
          () => restoreIdentifiedPlatformDrafts(snapshot, [
            IdentifiedPlatformDraftRow('new', target),
          ]),
          throwsStateError,
        );
        expect(target.cells, isEmpty);
        expect(legacy.cells.single.value, input);
      },
    );
  }

  test('duplicate identities are rejected before any target mutation', () {
    final a = PlatformRowDraft()..setValue(field, 'A');
    final b = PlatformRowDraft();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    expect(
      () => captureIdentifiedPlatformDrafts([
        IdentifiedPlatformDraftRow('same', a),
        IdentifiedPlatformDraftRow('same', b),
      ]),
      throwsStateError,
    );
    final snapshot = {
      'format': 'identified-platform-rows-v1',
      'rows': [
        {'localId': 'B', 'fields': a.exportDraft()},
        {'localId': 'B', 'fields': a.exportDraft()},
      ],
    };
    expect(
      () => restoreIdentifiedPlatformDrafts(snapshot, [
        IdentifiedPlatformDraftRow('B', b),
      ]),
      throwsStateError,
    );
    expect(b.cells, isEmpty);
  });

  test(
    'unmatched nonempty row blocks the whole restore before the first assignment',
    () {
      final a = PlatformRowDraft()..setValue(field, 'A');
      final b = PlatformRowDraft()..setValue(field, 'B');
      final target = PlatformRowDraft();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      addTearDown(target.dispose);
      final snapshot = captureIdentifiedPlatformDrafts([
        IdentifiedPlatformDraftRow('A', a),
        IdentifiedPlatformDraftRow('B', b),
      ]);
      expect(
        () => restoreIdentifiedPlatformDrafts(snapshot, [
          IdentifiedPlatformDraftRow('A', target),
        ]),
        throwsStateError,
      );
      expect(target.cells, isEmpty);
    },
  );

  test(
    'invalid later metadata cannot leave earlier product values restored',
    () {
      final value = PlatformRowDraft()..setValue(field, 'FIRST');
      final a = PlatformRowDraft();
      final b = PlatformRowDraft();
      addTearDown(value.dispose);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final snapshot = {
        'format': 'identified-platform-rows-v1',
        'rows': [
          {'localId': 'A', 'fields': value.exportDraft()},
          {
            'localId': 'B',
            'fields': {'cells': 42},
          },
        ],
      };
      expect(
        () => restoreIdentifiedPlatformDrafts(snapshot, [
          IdentifiedPlatformDraftRow('A', a),
          IdentifiedPlatformDraftRow('B', b),
        ]),
        throwsA(isA<TypeError>()),
      );
      expect(a.cells, isEmpty);
      expect(b.cells, isEmpty);
    },
  );
  test('identified manifest cannot silently omit a restored business row', () {
    final a = PlatformRowDraft();
    final b = PlatformRowDraft();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final snapshot = captureIdentifiedPlatformDrafts([
      IdentifiedPlatformDraftRow('A', a),
    ]);
    expect(
      () => restoreIdentifiedPlatformDrafts(snapshot, [
        IdentifiedPlatformDraftRow('A', a),
        IdentifiedPlatformDraftRow('B', b),
      ]),
      throwsStateError,
    );
  });
}
