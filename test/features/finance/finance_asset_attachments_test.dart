import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/models/finance_asset_models.dart';
import 'package:uten_imp/features/finance/widgets/finance_asset_detail.dart';
import 'package:uten_imp/features/finance/widgets/finance_asset_ui.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final ledger in FinanceAssetLedger.values) {
    testWidgets(
      '${ledger.name} keeps references and binds files to the actual record',
      (tester) async {
        final api = _AssetFileApi();
        await _pump(tester, api, ledger: ledger);
        final section = tester.widget<BusinessAttachmentSection>(
          find.byType(BusinessAttachmentSection),
        );
        expect(section.ownerId, _AssetFileApi.id);
        expect(
          section.ownerType,
          ledger == FinanceAssetLedger.fixedAsset
              ? 'FINANCE_ASSET'
              : 'FINANCE_DEFERRED_EXPENSE',
        );
        expect(section.canManage, isTrue);
        expect(find.text('合同-20260909'), findsOneWidget);
        expect(find.text('GL-20260909'), findsOneWidget);
        expect(api.files, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scenario in [
    (status: 'PENDING_APPROVAL', editAllowed: true),
    (status: 'ACTIVE', editAllowed: true),
    (status: 'DRAFT', editAllowed: false),
  ]) {
    testWidgets(
      '${scenario.status} server edit ${scenario.editAllowed} is respected',
      (tester) async {
        await _pump(
          tester,
          _AssetFileApi(
            status: scenario.status,
            editAllowed: scenario.editAllowed,
          ),
        );
        final section = tester.widget<AttachmentSection>(
          find.byType(AttachmentSection),
        );
        expect(section.ownerCanUpload, isFalse);
        expect(section.ownerCanDelete, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final permission in [Perm.financeViewAll, Perm.financeAssetView]) {
    testWidgets('missing $permission hides original files', (tester) async {
      final api = _AssetFileApi();
      await _pump(tester, api, omit: permission);
      expect(find.byType(AttachmentSection), findsNothing);
      expect(api.files, 0);
    });
  }
}

Future<void> _pump(
  WidgetTester tester,
  _AssetFileApi api, {
  FinanceAssetLedger ledger = FinanceAssetLedger.fixedAsset,
  String? omit,
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final permissions = {
    Perm.financeAssetView,
    Perm.financeAssetEdit,
    Perm.financeViewAll,
    Perm.attachmentView,
    Perm.attachmentUpload,
    Perm.attachmentDelete,
    Perm.attachmentDownload,
  }..remove(omit);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: FinanceAssetDetailSurface(
            ledger: ledger,
            id: 'route-id',
            showClose: false,
            capabilities: const FinanceAssetCapabilities(
              canView: true,
              canEdit: true,
              canApprove: false,
              canPost: false,
              canDispose: false,
              canManagePeriod: false,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _AssetFileApi extends ApiClient {
  _AssetFileApi({this.status = 'DRAFT', this.editAllowed = true})
    : super(Dio());
  static const id = 'ff9c8a54-dad9-410b-90ef-55e19f7bb8f1';
  final String status;
  final bool editAllowed;
  int files = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'summary': {
      'id': id,
      'code': 'ZC-001',
      'name': '装配设备',
      'status': status,
      'rowVersion': 1,
      'allowedActions': editAllowed ? ['EDIT'] : <String>[],
    },
    'documentReferences': ['合同-20260909'],
    'voucherNumbers': ['GL-20260909'],
    'books': <Object>[],
    'schedule': <Object>[],
    'approvalSteps': <Object>[],
    'events': <Object>[],
  };
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('attachments')) files++;
    return const [];
  }
}
