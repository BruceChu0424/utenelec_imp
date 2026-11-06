import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'dart:convert';
import 'dart:async';
import 'package:flutter_riverpod/legacy.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/finance/widgets/finance_payroll_preparation.dart';
import 'package:uten_imp/features/finance/widgets/finance_payroll_deduction_allocations.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';
import 'package:uten_imp/shared/models/task_claim_view.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

final _testPermissions = StateProvider<Set<String>>(
  (ref) => {Perm.financeApplicationView, Perm.financeApplicationReview},
);
const _app = {
  'id': '10000000-0000-0000-0000-000000000001',
  'application_no': 'FQ原工资付款',
  'source_fingerprint': 'original-payroll-fingerprint',
  'row_version': 9,
  'requested_date': '2026-09-30',
};
const _one = {
  'id': 'item-a',
  'code': 'OTHER_DEDUCTION',
  'name': '其他扣除',
  'description': '原餐费明细',
  'type': 'DEDUCTION',
  'amount': '60',
  'employeeId': 'employee-a',
  'employeeCode': 'EA',
  'employeeName': '原员工甲',
};
const _two = {
  'id': 'item-b',
  'code': 'OTHER_DEDUCTION',
  'name': '其他扣除',
  'description': '原借款明细',
  'type': 'DEDUCTION',
  'amount': '40',
  'employeeId': 'employee-b',
  'employeeCode': 'EB',
  'employeeName': '原员工乙',
};
Map<String, dynamic> _share(
  String id,
  String purpose,
  String style,
  String amount,
) => {
  'id': id,
  'purpose': purpose,
  'styleId': style,
  'amount': amount,
  'sourceReference': '本原扣款的明确确认依据',
  if (purpose == 'EMPLOYEE_SETTLEMENT') 'auxiliaryId': 'aux-b',
  if (purpose == 'EMPLOYEE_SETTLEMENT')
    'original': {
      'kind': 'GL_AUXILIARY_BALANCE_POOL',
      'sourceId': 'aux-b',
      'sourceFingerprint': 'original-loan-fingerprint',
    },
};
Map<String, dynamic> _instruction() => {
  'mode': 'NATIVE_APPROVED_PAYROLL',
  'wagePayableStyleId': 'wage-custom',
  'expenseStyleByDepartment': {'dept': 'mfg'},
  'deductionAllocations': {
    'item-a': [_share('share-a', 'EXPENSE_REDUCTION', 'expense', '60')],
    'item-b': [_share('share-b', 'EMPLOYEE_SETTLEMENT', 'loan', '40')],
  },
  'deductionStyleByCode': <String, dynamic>{},
  'accountingAsOf': '2026-09-30',
  'originalEvidenceIds': ['proof'],
  'sourceReference': '原计提会计依据',
};

void main() {
  test(
    'same deduction code stays distinct by original item and typed reductions never carry a loan claim',
    () {
      final a = PayrollDeductionAllocationRow(
            _one,
            _share('a', 'EXPENSE_REDUCTION', 'expense', '20'),
            () {},
          ),
          b = PayrollDeductionAllocationRow(
            _one,
            _share('b', 'STANDARD_LIABILITY', 'tax', '40'),
            () {},
          ),
          other = PayrollDeductionAllocationRow(_two, {}, () {});
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      addTearDown(other.dispose);
      a.source = {
        'auxiliaryId': 'stale-loan',
        'original': {'kind': 'GL_ALLOCATION', 'sourceId': 'stale'},
      };
      expect(a.instruction()['auxiliaryId'], isNull);
      expect(a.instruction()['original'], isNull);
      expect(payrollDeductionAllocationStatus(_one, [a, b]), contains('已对应'));
      expect(
        payrollDeductionAllocationStatus(_two, [other]),
        contains('未填写完整'),
      );
      expect(a.item['id'], 'item-a');
      expect(other.item['id'], 'item-b');
      a.amount.text = '12.';
      expect(a.capture()['amount'], '12.');
      expect(_one['amount'], '60');
    },
  );
  test(
    'shares conserve the full original decimal and manufacturing is distinct from employee debt',
    () {
      final item = {..._one, 'amount': '1.000000000000000000000001'};
      final a = PayrollDeductionAllocationRow(
            item,
            _share('a', 'STANDARD_INCOME', 'income', '1'),
            () {},
          ),
          b = PayrollDeductionAllocationRow(
            item,
            _share(
              'b',
              'STANDARD_LIABILITY',
              'tax',
              '0.000000000000000000000001',
            ),
            () {},
          );
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      expect(payrollDeductionAllocationStatus(item, [a, b]), contains('已对应'));
      b.amount.text = '0.000000000000000000000002';
      expect(payrollDeductionAllocationStatus(item, [a, b]), contains('不一致'));
      expect(
        payrollDeductionStyleAllowed({
          'category': 'ACCOUNT',
          'costAllowed': true,
          'employeeSettlementAllowed': false,
        }, 'MANUFACTURING_COST_REDUCTION'),
        isTrue,
      );
      expect(
        payrollDeductionStyleAllowed({
          'category': 'ACCOUNT',
          'costAllowed': true,
          'employeeSettlementAllowed': false,
        }, 'EMPLOYEE_SETTLEMENT'),
        isFalse,
      );
      expect(
        payrollDeductionStyleAllowed({
          'category': 'ACCOUNT',
          'costAllowed': false,
          'employeeSettlementAllowed': true,
        }, 'MANUFACTURING_COST_REDUCTION'),
        isFalse,
      );
      expect(
        payrollDeductionAllocationStatus({..._one, 'amount': '0'}, []),
        '原金额为0',
      );
    },
  );
  testWidgets(
    'failed preparation receives new version and retries distinct original items without by-code grouping',
    (tester) async {
      final api = _Api()..issuesFirst = true;
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      expect(find.text('原制造部门'), findsWidgets);
      expect(find.text('原餐费明细'), findsWidgets);
      expect(find.text('原借款明细'), findsWidgets);
      final wage = tester.widget<UtenDropdownField>(
        find.byWidgetPredicate(
          (w) => w is UtenDropdownField && w.label == '应付工资科目',
        ),
      );
      expect(wage.items.map((x) => x.value), contains('wage-custom'));
      await tester.tap(find.text('核对并保存原会计准备'));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(1));
      expect(api.requests.first['expectedVersion'], 9);
      await tester.tap(find.text('核对并保存原会计准备'));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(2));
      expect(api.requests.last['expectedVersion'], 10);
      final instruction =
          api.requests.last['instruction'] as Map<String, dynamic>;
      expect(instruction['deductionStyleByCode'], isEmpty);
      expect(
        (instruction['deductionAllocations'] as Map).keys,
        containsAll(['item-a', 'item-b']),
      );
      final rows =
          (instruction['deductionAllocations'] as Map)['item-a'] as List;
      expect((rows.single as Map)['purpose'], 'EXPENSE_REDUCTION');
      expect((rows.single as Map)['original'], isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'unknown preparation survives hard close and frozen receipt recovery',
    (tester) async {
      final api = _Api()..loseFirst = true;
      final storage = MemoryFormDraftStorage();
      final first = await _mount(tester, api, storage);
      await tester.tap(find.text('核对并保存原会计准备'));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(1));
      final state =
          tester.state(find.byType(FinancePayrollPreparation))
              as FormDraftMixin<FinancePayrollPreparation>;
      await state.saveFormDraftNow();
      final draft = first.read(formDraftsProvider).single;
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      api.failReferences = true;
      final second = await _mount(tester, api, storage, resume: draft.id);
      await tester.tap(find.text('读取原请求回执'));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(1));
      expect(api.receipts, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      second.dispose();
    },
  );
  testWidgets(
    'reused accrual freezes its accounting shares and does not reselect already cleared debt',
    (tester) async {
      final api = _Api()..reused = true;
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      final wage = tester.widget<UtenDropdownField>(
        find.byWidgetPredicate(
          (w) => w is UtenDropdownField && w.label == '应付工资科目',
        ),
      );
      expect(wage.enabled, isFalse);
      await tester.tap(find.text('核对并保存原会计准备'));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(1));
      expect(api.sourceReads, 0);
      final allocations =
          (api.requests.single['instruction'] as Map)['deductionAllocations']
              as Map;
      expect(
        (((allocations['item-b'] as List).single as Map)['original']
            as Map)['sourceFingerprint'],
        'original-loan-fingerprint',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'nested allocation editor uses Uten grid without sticky duplicate header',
    (tester) async {
      final api = _Api();
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      final button = find.text('对应份额').first;
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      final grid = tester
          .widget<UtenEditableGrid<PayrollDeductionAllocationRow>>(
            find.byType(UtenEditableGrid<PayrollDeductionAllocationRow>),
          );
      expect(grid.stickyHeader, isFalse);
      expect(grid.controller.rows.single.item['id'], 'item-a');
      grid.controller.rows.single.amount.text = '12.';
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留份额并返回'));
      await tester.pumpAndSettle();
      final state =
          tester.state(find.byType(FinancePayrollPreparation))
              as FormDraftMixin<FinancePayrollPreparation>;
      await state.saveFormDraftNow();
      final saved = container.read(formDraftsProvider).single.data;
      final values = saved['deductionAllocations'] as Map;
      expect(((values['item-a'] as List).single as Map)['amount'], '12.');
      expect(financeAmountUnits(_one['amount']!.toString()), isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'existing net liability retains original deductions readonly without another loan clearance',
    (tester) async {
      final api = _Api();
      final prepared = {
        ..._instruction(),
        'mode': 'EXISTING_CONFIRMED_LIABILITY',
        'existingLiabilityBasis': 'NET_AFTER_DEDUCTIONS',
      };
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        instruction: prepared,
      );
      expect(find.textContaining('既有分录已经拆分扣款'), findsOneWidget);
      await tester.tap(find.text('核对并保存原会计准备'));
      await tester.pumpAndSettle();
      final instruction =
          api.requests.single['instruction'] as Map<String, dynamic>;
      expect(instruction['deductionAllocations'], isEmpty);
      expect(instruction['deductionSettlements'], isEmpty);
      expect(instruction['expenseStyleByDepartment'], isEmpty);
      expect(api.sourceReads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  for (final nonCash in [false, true]) {
    testWidgets(
      '${nonCash ? 'noncash voucher' : 'GL allocation'} picker completes every authorized page and preserves exact selected authority',
      (tester) async {
        final api = _Api()
          ..candidateCount = 125
          ..nonCashSource = nonCash;
        final instruction = {
          ..._instruction(),
          'mode': 'EXISTING_CONFIRMED_LIABILITY',
          'existingLiabilityBasis': nonCash
              ? 'NET_AFTER_DEDUCTIONS'
              : 'GROSS_BEFORE_DEDUCTIONS',
        };
        final container = await _mount(
          tester,
          api,
          MemoryFormDraftStorage(),
          instruction: instruction,
        );
        final button = find.text(nonCash ? '选择既有非现金原凭证' : '选择明确原应付工资GL来源');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        final reads = api.sourceQueries;
        expect(reads.map((q) => (q['page'], q['size'])), [(1, 100), (2, 100)]);
        expect(
          reads.every(
            (q) =>
                q['sourceFingerprint'] == _app['source_fingerprint'] &&
                q['expectedClaimId'] != null &&
                q['styleId'] == 'wage-custom',
          ),
          true,
        );
        final finder = find
            .byType(MasterDataTableView<Map<String, dynamic>>)
            .last;
        final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
          finder,
        );
        expect(table.items, hasLength(125));
        expect(table.items.map(table.rowKeyOf!).toSet(), hasLength(125));
        final selected = table.items.last;
        table.onRowTap!(selected);
        table.onRowTap!(selected);
        await tester.pumpAndSettle();
        if (nonCash) {
          expect(api.exactQueries, isEmpty);
        } else {
          expect(api.exactQueries.single['entryId'], 'entry-123');
          expect(api.exactQueries.single['allocationNo'], 1);
          expect(find.text('9.1234'), findsWidgets);
        }
        expect(find.textContaining('V124'), findsWidgets);
        expect(api.requests, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        container.dispose();
      },
    );
  }
  testWidgets(
    'a denied exact payroll-source preview retires the list even while cached local permissions still allow review',
    (tester) async {
      final api = _Api()
        ..candidateCount = 125
        ..denyCandidateSelection = true;
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        instruction: {
          ..._instruction(),
          'mode': 'EXISTING_CONFIRMED_LIABILITY',
          'existingLiabilityBasis': 'GROSS_BEFORE_DEDUCTIONS',
        },
      );
      final button = find.text('选择明确原应付工资GL来源');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      final finder = find
          .byType(MasterDataTableView<Map<String, dynamic>>)
          .last;
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        finder,
      );
      table.onRowTap!(table.items.last);
      await tester.pumpAndSettle();
      expect(find.text('原GL读取已被拒绝'), findsOneWidget);
      expect(find.text('V124'), findsNothing);
      expect(api.requests, isEmpty);
      expect(api.exactQueries, hasLength(1));
      table.onRowTap!(table.items.first);
      await tester.pump();
      expect(api.exactQueries, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'all-zero original source does not require a fabricated liability or noncash voucher',
    (tester) async {
      final api = _Api()..allZero = true;
      final prepared = {
        ..._instruction(),
        'mode': 'EXISTING_CONFIRMED_LIABILITY',
        'existingLiabilityBasis': 'NET_AFTER_DEDUCTIONS',
      };
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        instruction: prepared,
      );
      expect(find.textContaining('原工资应发、扣款及实发均为0'), findsOneWidget);
      expect(find.text('选择既有非现金原凭证'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is UtenDropdownField && widget.label == '应付工资科目',
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'late private payroll reference response stays retired after a permission ABA',
    (tester) async {
      final api = _Api()..referencesGate = Completer<void>();
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        settle: false,
      );
      await tester.pump();
      container.read(_testPermissions.notifier).state = {
        Perm.financeApplicationView,
      };
      await tester.pump();
      container.read(_testPermissions.notifier).state = {
        Perm.financeApplicationView,
        Perm.financeApplicationReview,
      };
      await tester.pump();
      api.referencesGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('原员工甲'), findsNothing);
      expect(find.text('原餐费明细'), findsNothing);
      expect(api.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'narrow enlarged payroll and its allocation popup retain Uten interactions',
    (tester) async {
      final container = await _mount(
        tester,
        _Api(),
        MemoryFormDraftStorage(),
        width: 390,
        scale: 1.5,
      );
      final button = find.text('对应份额').first;
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('原工资扣款份额对应'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('保留份额并返回'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Api api,
  MemoryFormDraftStorage storage, {
  String? resume,
  double width = 1400,
  double scale = 1,
  bool settle = true,
  Map<String, dynamic>? instruction,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://finance-draft.test/api'),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'finance-operator'),
      ),
      currentPermissionsProvider.overrideWith(
        (ref) => ref.watch(_testPermissions),
      ),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
      taskClaimRepositoryProvider.overrideWithValue(_Claims()),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: FinancePayrollPreparation(
            application: {
              ..._app,
              'payroll_instruction': instruction ?? _instruction(),
            },
            resumeDraftId: resume,
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return container;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Claims extends TaskClaimRepository {
  _Claims() : super(ApiClient(Dio()));
  TaskClaimView _view(String type, String key) => TaskClaimView(
    claimId: 'original-lease',
    targetType: type,
    targetKey: key,
    claimedBy: 'finance-employee',
    claimedByName: '原财务',
    claimedByMe: true,
    claimedAt: DateTime(2026),
    leaseUntil: DateTime(2099),
  );
  @override
  Future<TaskClaimView?> claimRequired(String type, String key) async =>
      _view(type, key);
  @override
  Future<TaskClaimView?> heartbeatRequired(
    String type,
    String key, {
    required String expectedClaimId,
  }) async => _view(type, key);
  @override
  Future<void> releaseRequired(
    String type,
    String key, {
    required String expectedClaimId,
  }) async {}
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  bool issuesFirst = false,
      loseFirst = false,
      failReferences = false,
      reused = false,
      allZero = false;
  Completer<void>? referencesGate;
  int receipts = 0, sourceReads = 0;
  int candidateCount = 0;
  bool nonCashSource = false;
  bool denyCandidateSelection = false;
  final sourceQueries = <Map<String, dynamic>>[];
  final exactQueries = <Map<String, dynamic>>[];
  final requests = <Map<String, dynamic>>[];
  Map<String, dynamic> _result() => {
    'row_version': requests.length + 9,
    'preparation': {
      'issues': issuesFirst && requests.length == 1
          ? [
              {
                'field': 'mapping',
                'sourceRow': 'item-a',
                'message': '原项依据需要补齐',
              },
            ]
          : <Object?>[],
      'instructionFingerprint': 'prepared-fingerprint',
    },
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/operations/')) {
      receipts++;
      return {'found': true, 'result': _result()};
    }
    if (path.endsWith('/payroll-gl-sources/page')) {
      sourceReads++;
      sourceQueries.add({...?query});
      final page = query!['page'] as int;
      final size = query['size'] as int;
      return {
        'items': [
          for (
            var i = (page - 1) * size;
            i < page * size && i < candidateCount;
            i++
          )
            {
              'entryId': i == 124 ? 'entry-123' : 'entry-$i',
              'allocationNo': i == 124 ? 1 : 0,
              'voucherId': 'voucher-$i',
              'voucherNo': 'V$i',
              'sourceAmountLocal': '100.0001',
              'ready': nonCashSource,
            },
        ],
        'page': page,
        'size': size,
        'total': candidateCount,
        'totalPages': (candidateCount + size - 1) ~/ size,
      };
    }
    if (path.endsWith('/payroll-gl-sources')) {
      sourceReads++;
      exactQueries.add({...?query});
      if (denyCandidateSelection) {
        throw ApiException('FORBIDDEN', '原GL读取已被拒绝', httpStatus: 403);
      }
      return {
        'items': [
          {
            ...query!,
            'voucherNo': 'V124',
            'ready': true,
            'amountLocal': '9.1234',
            'amountOriginal': '9.1234',
            'sourceFingerprint': 'exact-selected-proof',
          },
        ],
      };
    }
    if (referencesGate != null) {
      await referencesGate!.future;
    }
    if (failReferences) {
      throw ApiException(
        'CONFLICT',
        '原来源需重新核对',
        httpStatus: 409,
        hasResponseCode: true,
      );
    }
    return {
      'source': allZero
          ? {
              'grossIncome': '0',
              'totalDeduction': '0',
              'netIncome': '0',
              'slips': <Object?>[],
            }
          : {
              'period': '2026-09',
              'grossIncome': '1000',
              'totalDeduction': nonCashSource ? '1000' : '100',
              'netIncome': nonCashSource ? '0' : '900',
              'slips': [
                {
                  'id': 'slip-a',
                  'employeeId': 'employee-a',
                  'employeeCode': 'EA',
                  'employeeName': '原员工甲',
                  'departmentId': 'dept',
                  'departmentName': '原制造部门',
                  'items': [_one],
                },
                {
                  'id': 'slip-b',
                  'employeeId': 'employee-b',
                  'employeeCode': 'EB',
                  'employeeName': '原员工乙',
                  'departmentId': 'dept',
                  'departmentName': '原制造部门',
                  'items': [_two],
                },
              ],
            },
      'departments': [
        {'id': 'dept', 'name': '当前已改名部门'},
      ],
      'styles': [
        {
          'id': 'wage-custom',
          'code': 'CUSTOM',
          'name': '明确原应付职工薪酬',
          'category': 'LIABILITY',
          'wageAllowed': true,
        },
        {
          'id': 'mfg',
          'code': '410106',
          'name': '加工人工',
          'category': 'ACCOUNT',
          'costAllowed': true,
        },
        {
          'id': 'expense',
          'code': '5602',
          'name': '原费用',
          'category': 'EXPENSE',
          'costAllowed': true,
        },
        {
          'id': 'loan',
          'code': '1221',
          'name': '员工借款',
          'category': 'ACCOUNT',
          'employeeSettlementAllowed': true,
        },
      ],
      'evidence': [
        {'id': 'proof', 'name': '原工资依据'},
      ],
      'reusedAccrual': reused,
      if (reused) 'accrual': {'instruction': _instruction()},
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    requests.add(jsonDecode(jsonEncode(body)) as Map<String, dynamic>);
    if (loseFirst && requests.length == 1) {
      throw NetworkTimeoutException();
    }
    return _result();
  }
}
