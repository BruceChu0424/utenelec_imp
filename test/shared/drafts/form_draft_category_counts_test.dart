import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/badges/badge_scope.dart';
import 'package:uten_imp/shared/badges/effective_badge_summary_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/document_status_counts_provider.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';

import '../../helpers/badge_summary_fixture.dart';

class _Drafts extends FormDraftsNotifier {
  _Drafts(this.drafts);
  final List<FormDraft> drafts;
  @override
  List<FormDraft> build() => drafts;
}

FormDraft _draft(
  String id,
  BadgeModule module,
  String? kind,
  String route, {
  Map<String, dynamic> data = const {},
}) => FormDraft(
  id: id,
  title: '草稿 $id',
  module: module,
  draftKind: kind,
  route: route,
  permission: '',
  updatedAt: DateTime.now(),
  data: data,
);

void main() {
  test(
    'document buckets add local once and never mutate formal facts',
    () async {
      final drafts = [
        _draft('new', BadgeModule.sales, 'salesOrder', '/sales/orders/new'),
        _draft(
          'already-created',
          BadgeModule.sales,
          'salesOrder',
          '/sales/orders/new',
          data: {'createdDocId': 'formal-1'},
        ),
      ];
      final container = ProviderContainer(
        overrides: [
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              entries: {BadgeEntry.salesDrafts: (2, 0)},
              facts: {'drafts.salesOrder': 2},
            ),
          ),
          formDraftsProvider.overrideWith(() => _Drafts(drafts)),
          documentStatusCountsProvider.overrideWith(
            (ref, scope) async => {'DRAFT': 2, 'APPROVED': 7},
          ),
        ],
      );
      addTearDown(container.dispose);
      const scope = DocumentStatusScope(DraftDocKind.salesOrder);
      await container.read(documentStatusCountsProvider(scope).future);
      expect(
        container
            .read(effectiveDocumentStatusCountsProvider(scope))
            .valueOrNull,
        {'DRAFT': 3, 'APPROVED': 7},
      );
      expect(container.read(draftCountsProvider).salesOrder, 3);
      expect(container.read(badgeModuleTodoProvider(BadgeModule.sales)), 3);
      expect(container.read(badgeSummaryProvider).fact('drafts.salesOrder'), 2);
    },
  );

  test(
    'legacy customer shipment null kind belongs to shipment category once',
    () async {
      final container = ProviderContainer(
        overrides: [
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(facts: {'drafts.salesShipment': 2}),
          ),
          formDraftsProvider.overrideWith(
            () => _Drafts([
              _draft(
                'normal',
                BadgeModule.sales,
                'salesShipment',
                '/sales/shipments/new',
              ),
              _draft(
                'customer',
                BadgeModule.sales,
                null,
                '/sales/customer-shipments/new',
              ),
            ]),
          ),
          documentStatusCountsProvider.overrideWith(
            (ref, scope) async => {'DRAFT': 2},
          ),
        ],
      );
      addTearDown(container.dispose);
      const normal = DocumentStatusScope(DraftDocKind.salesShipment);
      const customer = DocumentStatusScope(
        DraftDocKind.salesShipment,
        shipmentKind: 'DIRECT_CUSTOMER',
      );
      await container.read(documentStatusCountsProvider(normal).future);
      await container.read(documentStatusCountsProvider(customer).future);
      expect(container.read(draftCountsProvider).salesShipment, 4);
      expect(
        container
            .read(effectiveDocumentStatusCountsProvider(normal))
            .valueOrNull?['DRAFT'],
        4,
      );
      expect(
        container
            .read(effectiveDocumentStatusCountsProvider(customer))
            .valueOrNull?['DRAFT'],
        3,
      );
    },
  );

  test(
    'warehouse aggregate includes transfer and check slices exactly once',
    () async {
      final container = ProviderContainer(
        overrides: [
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              facts: {
                'drafts.stockDocument': 5,
                'drafts.stockTransfer': 2,
                'drafts.stockCheck': 1,
              },
            ),
          ),
          formDraftsProvider.overrideWith(
            () => _Drafts([
              _draft(
                'draw',
                BadgeModule.warehouse,
                'stockDocument',
                '/warehouse/DRAW/new',
              ),
              _draft(
                'transfer',
                BadgeModule.warehouse,
                'stockTransfer',
                '/warehouse/TRANSFER/new',
              ),
              _draft(
                'check',
                BadgeModule.warehouse,
                'stockCheck',
                '/warehouse/CHECK/new',
              ),
            ]),
          ),
          documentStatusCountsProvider.overrideWith(
            (ref, scope) async => {'DRAFT': 2},
          ),
        ],
      );
      addTearDown(container.dispose);
      final counts = container.read(draftCountsProvider);
      expect(counts.stockDocument, 8);
      expect(counts.stockTransfer, 3);
      expect(counts.stockCheck, 2);
      const transfer = DocumentStatusScope(
        DraftDocKind.stockDocument,
        docType: 'TRANSFER',
      );
      await container.read(documentStatusCountsProvider(transfer).future);
      expect(
        container
            .read(effectiveDocumentStatusCountsProvider(transfer))
            .valueOrNull?['DRAFT'],
        3,
      );
    },
  );

  test(
    'task composite includes formal and local drafts once; master checkpoints remain visible',
    () {
      final container = ProviderContainer(
        overrides: [
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              entries: {
                BadgeEntry.purchaseTaskCenter: (3, 4),
                BadgeEntry.purchaseDrafts: (2, 0),
              },
            ),
          ),
          formDraftsProvider.overrideWith(
            () => _Drafts([
              _draft(
                'order',
                BadgeModule.purchase,
                'purchaseOrder',
                '/purchase/orders/new',
              ),
              _draft(
                'supplier',
                BadgeModule.purchase,
                null,
                '/basicinfo/supplier?draftForm=master',
                data: {'createdId': 'supplier-1'},
              ),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      const scope = BadgeScope.entry(
        BadgeEntry.purchaseTaskCenter,
        additionalTodoEntries: {
          BadgeEntry.purchaseTaskCenter,
          BadgeEntry.purchaseDrafts,
        },
      );
      expect(
        container.read(badgeScopeCountsProvider(scope)),
        const BadgeCounts(7, 4),
      );
      expect(
        container.read(formDraftModuleCountProvider(BadgeModule.purchase)),
        2,
      );
      expect(container.read(badgeTotalTodoProvider), 7);
    },
  );
}
