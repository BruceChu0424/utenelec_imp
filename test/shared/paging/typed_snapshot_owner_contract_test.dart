import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/finance/payables/models/finance_payable.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

Future<PagedReadSnapshot<FinancePayableItem, FinancePayablesResult>> _finance(
  ScopedPagedRead<FinancePayableItem> reader, {
  required bool empty,
  required String scope,
}) async {
  final result = await reader.read(
    1,
    scope: scope,
    isCurrent: () => true,
    fetchPage: (page) async {
      final response = FinancePayablesResult(
        summary: FinancePayablesSummary(
          outstandingLocal: page == 1 ? '9007199254740993.0001' : '99.99',
          pendingLossCases: page == 1 ? 7 : 99,
        ),
        items: empty
            ? const []
            : [
                FinancePayableItem(
                  id: 'payable-$page',
                  version: 11,
                  openItemKind: 'PAYABLE',
                  legacyImported: true,
                  sourceDocType: 'PURCHASE_RECEIPT',
                  outstandingOriginal: '9007199254740993.0001',
                ),
              ],
        page: page,
        size: 1,
        total: empty ? 0 : 2,
        totalPages: empty ? 0 : 2,
      );
      return PagedReadSnapshot<FinancePayableItem, FinancePayablesResult>(
        page: PagedResult(
          items: response.items,
          page: response.page,
          size: response.size,
          total: response.total,
          totalPages: response.totalPages,
        ),
        snapshot: response,
        rebuildSnapshot: response.withPage,
      );
    },
  );
  return result as PagedReadSnapshot<FinancePayableItem, FinancePayablesResult>;
}

Future<PagedReadSnapshot<AuditLogEntry, AuditLogPage>> _emptyAudit(
  ScopedPagedRead<AuditLogEntry> reader,
  String scope,
) async {
  const response = AuditLogPage(
    items: [],
    page: 1,
    size: 100,
    total: 0,
    totalPages: 0,
    snapshotId: 700,
    readScopeVersion: 'audit-current-authority',
  );
  final result = await reader.read(
    1,
    scope: scope,
    isCurrent: () => true,
    fetchPage: (_) async => PagedReadSnapshot<AuditLogEntry, AuditLogPage>(
      page: response,
      snapshot: response,
    ),
  );
  return result as PagedReadSnapshot<AuditLogEntry, AuditLogPage>;
}

void main() {
  for (final empty in [false, true]) {
    test(
      'actual finance ${empty ? 'empty' : 'nonempty'} callback DTO shares its one owner-bound list and retires without invalidating another empty result',
      () async {
        final reader = ScopedPagedRead<FinancePayableItem>(
          idOf: (row) => row.id,
        );
        final other = ScopedPagedRead<FinancePayableItem>(
          idOf: (row) => row.id,
        );
        addTearDown(reader.dispose);
        addTearDown(other.dispose);
        final result = await _finance(reader, empty: empty, scope: 'first');
        final typed = result.snapshot;
        expect(identical(typed.items, result.items), isTrue);
        expect(typed.items, hasLength(empty ? 0 : 2));
        expect(typed.summary.outstandingLocal, '9007199254740993.0001');
        expect(typed.summary.pendingLossCases, 7);
        if (!empty) {
          expect(typed.items.map((row) => row.version), everyElement(11));
          expect(
            typed.items.map((row) => row.canCreatePayment),
            everyElement(isFalse),
          );
          expect(typed.items.last.outstandingOriginal, '9007199254740993.0001');
        }
        final outerProof = readWindowBindingOf(result.items)!;
        final typedProof = readWindowBindingOf(typed.items)!;
        expect(typedProof.sameSession(outerProof), isTrue);
        expect(typedProof.isCurrent, isTrue);
        final independentEmpty = await _finance(
          other,
          empty: true,
          scope: 'second',
        );
        final independentProof = readWindowBindingOf(
          independentEmpty.snapshot.items,
        )!;
        expect(
          identical(typed.items, independentEmpty.snapshot.items),
          isFalse,
        );
        expect(typedProof.sameSession(independentProof), isFalse);
        reader.invalidate();
        expect(outerProof.isCurrent, isFalse);
        expect(typedProof.isCurrent, isFalse);
        expect(independentProof.isCurrent, isTrue);
        expect(readWindowBindingOf(const <FinancePayableItem>[]), isNull);
      },
    );
  }
  test(
    'actual empty audit PagedResult DTO without a rebuild callback shares the typed clone owner and keeps another empty audit current',
    () async {
      final reader = ScopedPagedRead<AuditLogEntry>();
      final other = ScopedPagedRead<AuditLogEntry>();
      addTearDown(reader.dispose);
      addTearDown(other.dispose);
      final result = await _emptyAudit(reader, 'first-audit');
      final typed = result.snapshot;
      expect(identical(result.items, typed.items), isTrue);
      expect(typed.items, isEmpty);
      expect(typed.snapshotId, 700);
      expect(typed.readScopeVersion, 'audit-current-authority');
      final outerProof = readWindowBindingOf(result.items)!;
      final typedProof = readWindowBindingOf(typed.items)!;
      expect(typedProof.sameSession(outerProof), isTrue);
      expect(typedProof.isCurrent, isTrue);
      final independent = await _emptyAudit(other, 'second-audit');
      final independentProof = readWindowBindingOf(independent.snapshot.items)!;
      expect(identical(result.items, independent.items), isFalse);
      expect(typedProof.sameSession(independentProof), isFalse);
      reader.invalidate();
      expect(outerProof.isCurrent, isFalse);
      expect(typedProof.isCurrent, isFalse);
      expect(independentProof.isCurrent, isTrue);
      expect(readWindowBindingOf(const <AuditLogEntry>[]), isNull);
    },
  );
}
