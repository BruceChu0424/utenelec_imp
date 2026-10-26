import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_outbound_detail_table.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import 'outbound_weight_fakes.dart';
import 'subcontract_outbound_test_support.dart';

SubcontractOutboundLineDraft _draft(String id) => SubcontractOutboundLineDraft(
  OutboundPickLine.fromJson(
    outboundPickLine(issueItemId: id, planItemId: 'plan-$id'),
  ),
  SubcontractDocItem.fromJson(outboundDocItem(id: id, planItemId: 'plan-$id')),
);

void main() {
  for (final batch in [false, true]) {
    testWidgets(
      '${batch ? 'batch' : 'single'} outbound keeps adapter, focus and composing through parent rebuilds',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(2400, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final a = _draft('a'), b = _draft('b'), replacement = _draft('a');
        addTearDown(a.dispose);
        addTearDown(b.dispose);
        addTearDown(replacement.dispose);
        var rows = [a];
        var warehouse = 'actual-leaf';
        var callbackVersion = -1;
        final revision = ValueNotifier(0);
        addTearDown(revision.dispose);
        final weights = FakeWeightRepository();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              fakeWeightRepositoryOverride(weights),
              apiClientProvider.overrideWithValue(
                SubcontractOutboundFakeApi(issues: 0),
              ),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: ValueListenableBuilder<int>(
                  valueListenable: revision,
                  builder: (_, version, _) => SubcontractOutboundDetailTable(
                    rows: [
                      for (final draft in rows)
                        SubcontractOutboundTableRow(
                          draft: draft,
                          warehouse: warehouse,
                          warehouseId: warehouse,
                          documentNo: batch ? 'DOC-${draft.draftItemId}' : null,
                          onWarehouseChanged: (_) => callbackVersion = version,
                        ),
                    ],
                    editable: true,
                    showOrder: batch,
                    selectable: batch,
                    onChanged: () => revision.value++,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        UtenEditableGrid<SubcontractOutboundTableRow> grid() => tester.widget(
          find.byType(UtenEditableGrid<SubcontractOutboundTableRow>),
        );
        final controller = grid().controller;
        final adapter = controller.rows.single;
        var structureEvents = 0;
        controller.rowsListenable.addListener(() => structureEvents++);
        final field = find.byKey(
          const ValueKey('subcontract-outbound-a-quantity'),
        );
        await tester.showKeyboard(field);
        a.qty.value = const TextEditingValue(
          text: '80',
          selection: TextSelection.collapsed(offset: 1),
          composing: TextRange(start: 0, end: 1),
        );
        await tester.pump();
        final editable = tester.widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        );
        final focus = editable.focusNode;
        final requestCount = weights.requests.length;
        for (var i = 0; i < 4; i++) {
          revision.value++;
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(controller.rows.single, same(adapter));
        expect(structureEvents, 0);
        expect(tester.widget<TextField>(field).controller, same(a.qty));
        expect(focus.hasFocus, isTrue);
        expect(a.qty.value.composing, const TextRange(start: 0, end: 1));
        expect(weights.requests, hasLength(requestCount));
        controller.rows.single.onWarehouseChanged!(null);
        expect(callbackVersion, revision.value);
        warehouse = 'actual-leaf-b';
        revision.value++;
        await tester.pumpAndSettle();
        expect(controller.rows.single, same(adapter));
        expect(adapter.warehouseId, warehouse);
        expect(a.weight.currentWarehouseId, warehouse);
        expect(weights.requests.length, greaterThan(requestCount));
        rows = [a, b];
        revision.value++;
        await tester.pumpAndSettle();
        expect(controller.rows, hasLength(2));
        expect(controller.rows.first, same(adapter));
        rows = [replacement, b];
        revision.value++;
        await tester.pumpAndSettle();
        expect(controller.rows.first, isNot(same(adapter)));
        expect(controller.rows.first.draft, same(replacement));
        rows = [replacement];
        revision.value++;
        await tester.pumpAndSettle();
        expect(controller.rows, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
