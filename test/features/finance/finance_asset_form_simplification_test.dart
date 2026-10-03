import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/layout/uten_collapsible_section.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/finance/models/finance_asset_category_models.dart';
import 'package:uten_imp/features/finance/models/finance_asset_models.dart';
import 'package:uten_imp/features/finance/repositories/finance_asset_category_repository.dart';
import 'package:uten_imp/features/finance/repositories/finance_asset_workbench_repository.dart';
import 'package:uten_imp/features/finance/widgets/finance_asset_form_v2.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final ledger in FinanceAssetLedger.values) {
    testWidgets(
      '${ledger.name} keeps required fields outside optional groups',
      (tester) async {
        for (final width in [375.0, 1200.0]) {
          await _pump(tester, ledger: ledger, width: width);
          expect(_section(tester, 'additional').expanded, isFalse);
          expect(_section(tester, 'source').expanded, isFalse);
          expect(
            find.ancestor(
              of: find.byType(UtenDepartmentPicker),
              matching: find.byType(UtenCollapsibleSection),
            ),
            findsNothing,
          );
          expect(find.text('编号保存后自动生成'), findsOneWidget);
          expect(find.textContaining('附件服务尚未启用'), findsNothing);
          expect(tester.takeException(), isNull, reason: '$width');
          await tester.pumpWidget(const SizedBox());
        }
        for (final locale in [const Locale('en'), const Locale('ko')]) {
          await _pump(tester, ledger: ledger, locale: locale);
          final english = locale.languageCode == 'en';
          expect(
            _section(tester, 'additional').title,
            english ? 'Additional details (optional)' : '추가 정보(선택)',
          );
          expect(
            _section(tester, 'source').title,
            english ? 'Sources (before submission)' : '원본 문서(제출 전 입력)',
          );
          expect(
            find.text(
              english
                  ? 'The number is generated after saving.'
                  : '번호는 저장 후 자동 생성됩니다.',
            ),
            findsOneWidget,
          );
          expect(
            find.textContaining(
              ledger == FinanceAssetLedger.fixedAsset
                  ? (english ? 'Depreciation starts:' : '감가상각 시작월:')
                  : (english ? 'Amortization plan:' : '상각 계획:'),
            ),
            findsOneWidget,
          );
          expect(
            find.textContaining(
              english ? 'After saving the draft,' : '초안 저장 후 상세 화면에서',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      },
    );

    testWidgets('${ledger.name} preserves collapsed values on failed save', (
      tester,
    ) async {
      final repository = _Repository();
      await _pump(
        tester,
        ledger: ledger,
        repository: repository,
        existing: _existing(ledger),
      );
      expect(_section(tester, 'additional').expanded, isTrue);
      expect(_section(tester, 'source').expanded, isTrue);
      await _toggle(tester, '补充资料(选填)');
      await _toggle(tester, '来源单据(提交前补齐)');
      await tester.tap(find.byKey(const Key('finance-asset-form-save')));
      await tester.pumpAndSettle();

      final input = repository.saved!;
      expect(input.amount, '123456789.01');
      expect(input.sourceId, 'source-uuid');
      expect(input.sourceRef, '合同-001');
      expect(input.sourceLineRef, 'LINE-2');
      expect(input.sourceDocumentDate, '2026-01-02');
      expect(input.expectedVersion, 7);
      expect(input.location, '一号仓库');
      expect(input.costCenterCode, 'CC-001');
      expect(input.remark, '保留原始说明');
      expect(
        input.startPeriod,
        ledger == FinanceAssetLedger.fixedAsset ? '2026-02' : '2026-01',
      );
      expect(_input(tester, '备注').text, '保留原始说明');
      expect(_section(tester, 'additional').expanded, isFalse);
      expect(_section(tester, 'source').expanded, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('invalid collapsed optional input is revealed and blocks save', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(
      tester,
      repository: repository,
      existing: _existing(FinanceAssetLedger.fixedAsset),
    );
    _input(tester, '设备序列号').text = 'x' * 161;
    await _toggle(tester, '补充资料(选填)');
    await tester.tap(find.byKey(const Key('finance-asset-form-save')));
    await tester.pumpAndSettle();
    expect(repository.saved, isNull);
    expect(_section(tester, 'additional').expanded, isTrue);
    await tester.ensureVisible(
      find.byWidgetPredicate(
        (widget) => widget is UtenInput && widget.label == '设备序列号',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('设备序列号不能超过 160 个字符'), findsOneWidget);
    expect(_input(tester, '设备序列号').text, 'x' * 161);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid acceptance date reveals its optional group', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(
      tester,
      repository: repository,
      existing: _existing(
        FinanceAssetLedger.fixedAsset,
        acceptanceDate: '2025-12-01',
      ),
    );
    await _toggle(tester, '补充资料(选填)');
    await tester.tap(find.byKey(const Key('finance-asset-form-save')));
    await tester.pumpAndSettle();
    expect(repository.saved, isNull);
    expect(_section(tester, 'additional').expanded, isTrue);
    expect(find.text('验收日期不能早于取得日期'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _toggle(WidgetTester tester, String title) async {
  final target = find.text(title);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

UtenCollapsibleSection _section(WidgetTester tester, String name) =>
    tester.widget<UtenCollapsibleSection>(
      find.byKey(ValueKey('finance-asset-$name-details')),
    );

TextEditingController _input(WidgetTester tester, String label) => tester
    .widget<UtenInput>(
      find.byWidgetPredicate(
        (widget) => widget is UtenInput && widget.label == label,
      ),
    )
    .controller!;

FinanceAssetSummary _existing(
  FinanceAssetLedger ledger, {
  String acceptanceDate = '2026-01-05',
}) => FinanceAssetSummary.fromJson({
  'id': 'asset-1',
  'code': 'ZC-001',
  'name': '设备或待摊费用',
  'status': 'DRAFT',
  'originalValue': '123456789.01',
  'totalAmount': '123456789.01',
  'usefulMonths': 12,
  'salvageRate': '0.05',
  'departmentId': 'department-1',
  'departmentName': '财务部',
  'acquisitionDate': '2026-01-01',
  'readyForUseDate': '2026-01-10',
  'acceptanceDate': acceptanceDate,
  'benefitStartDate': '2026-01-01',
  'benefitEndDate': '2026-12-31',
  'serialNumber': 'SERIAL-1',
  'assetTag': 'TAG-1',
  'costCenterCode': 'CC-001',
  'location': '一号仓库',
  'sourceType': 'CONTRACT',
  'sourceId': 'source-uuid',
  'sourceRef': '合同-001',
  'sourceLineRef': 'LINE-2',
  'sourceDocumentDate': '2026-01-02',
  'remark': '保留原始说明',
  'version': 7,
}, ledger);

Future<void> _pump(
  WidgetTester tester, {
  FinanceAssetLedger ledger = FinanceAssetLedger.fixedAsset,
  FinanceAssetSummary? existing,
  _Repository? repository,
  double width = 1200,
  Locale locale = const Locale('zh'),
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(_Api()),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({
          Perm.financeAssetView,
          Perm.financeAssetEdit,
        }),
        financeAssetWorkbenchRepositoryProvider.overrideWithValue(
          repository ?? _Repository(),
        ),
        financeAssetCategoryRepositoryProvider.overrideWithValue(_Categories()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: FinanceAssetFormSurface(ledger: ledger, existing: existing),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Repository implements FinanceAssetWorkbenchRepository {
  FinanceAssetDraftInput? saved;

  @override
  Future<FinanceAssetWorkflowResponse> updateDraft(
    FinanceAssetLedger ledger,
    String id,
    FinanceAssetDraftInput input,
  ) async {
    saved = input;
    throw StateError('offline');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Categories implements FinanceAssetCategoryRepository {
  @override
  Future<List<FinanceAssetCategory>> list(
    FinanceAssetLedger objectType,
  ) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {};

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}
