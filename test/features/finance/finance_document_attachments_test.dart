import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _owners = {
  FinanceDocType.receipt: 'FINANCE_RECEIPT',
  FinanceDocType.payment: 'FINANCE_PAYMENT',
  FinanceDocType.expense: 'FINANCE_EXPENSE',
  FinanceDocType.otherIncome: 'FINANCE_OTHER_INCOME',
  FinanceDocType.bankTransfer: 'FINANCE_BANK_TRANSFER',
};

void main() {
  for (final entry in _owners.entries) {
    testWidgets('${entry.key.name} binds files to saved document UUID', (
      tester,
    ) async {
      final api = _FinanceFileApi();
      await _pump(tester, api, type: entry.key);
      final section = tester.widget<BusinessAttachmentSection>(
        find.byType(BusinessAttachmentSection),
      );
      expect(section.ownerType, entry.value);
      expect(section.ownerId, _FinanceFileApi.documentId);
      expect(section.canManage, isTrue);
      final rendered = tester.widget<AttachmentSection>(
        find.byType(AttachmentSection),
      );
      expect(rendered.ownerCanUpload, isTrue);
      expect(rendered.ownerCanDelete, isTrue);
      expect(api.fileQueries.single['ownerId'], _FinanceFileApi.documentId);
      expect(api.fileQueries.single['ownerType'], entry.value);
      expect(tester.takeException(), isNull);
    });
  }

  for (final state in [
    (name: 'approved', status: 1, closed: false, writable: true),
    (name: 'reversed', status: -1, closed: false, writable: true),
    (name: 'closed draft', status: 0, closed: true, writable: true),
    (name: 'view-only scope', status: 0, closed: false, writable: false),
  ]) {
    testWidgets('${state.name} retains files without modification controls', (
      tester,
    ) async {
      await _pump(
        tester,
        _FinanceFileApi(
          status: state.status,
          closed: state.closed,
          writable: state.writable,
        ),
      );
      final section = tester.widget<AttachmentSection>(
        find.byType(AttachmentSection),
      );
      expect(section.ownerCanUpload, isFalse);
      expect(section.ownerCanDelete, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final missing in [
    Perm.financeViewAll,
    Perm.financeReceiptView,
    Perm.attachmentView,
  ]) {
    testWidgets('missing $missing hides files and never fetches filenames', (
      tester,
    ) async {
      final api = _FinanceFileApi();
      await _pump(tester, api, omit: missing);
      expect(find.byType(AttachmentSection), findsNothing);
      expect(api.fileQueries, isEmpty);
    });
  }

  testWidgets('missing document edit permission keeps the files read-only', (
    tester,
  ) async {
    await _pump(tester, _FinanceFileApi(), omit: Perm.financeReceiptEdit);
    final section = tester.widget<AttachmentSection>(
      find.byType(AttachmentSection),
    );
    expect(section.ownerCanUpload, isFalse);
    expect(section.ownerCanDelete, isFalse);
  });

  testWidgets('prepayment files require the additional prepayment authority', (
    tester,
  ) async {
    final api = _FinanceFileApi(prepayment: true);
    await _pump(tester, api, omit: Perm.customerPrepaymentView);
    expect(find.byType(AttachmentSection), findsNothing);
    expect(api.fileQueries, isEmpty);
  });
}

Future<void> _pump(
  WidgetTester tester,
  _FinanceFileApi api, {
  FinanceDocType type = FinanceDocType.receipt,
  String? omit,
}) async {
  tester.view.physicalSize = const Size(1280, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final config = FinanceDocConfig.by(type);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final permissions = {
    config.listPerm,
    config.editPerm!,
    Perm.financeViewAll,
    Perm.customerPrepaymentView,
    Perm.attachmentView,
    Perm.attachmentUpload,
    Perm.attachmentDelete,
    Perm.attachmentDownload,
  }..remove(omit);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: FinanceDocDetailPage(docType: type, id: 'route-id'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FinanceFileApi extends ApiClient {
  _FinanceFileApi({
    this.status = 0,
    this.closed = false,
    this.writable = true,
    this.prepayment = false,
  }) : super(Dio());

  static const documentId = 'e65a0a91-4302-430b-adc6-f8277a947893';
  static const makerId = '88c21312-0a3e-4e03-a872-9acbff33cf37';
  final int status;
  final bool closed;
  final bool writable;
  final bool prepayment;
  final fileQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('scope')) {
      return {
        'scope': 'finance',
        'writeAll': false,
        'writableOwnerIds': writable ? [makerId] : <String>[],
      };
    }
    return {
      'id': documentId,
      'billNo': 'FY-20260909-001',
      'billDate': '2026-09-09',
      'makerId': makerId,
      'status': status,
      'closed': closed,
      'receiptKind': prepayment ? 'CUSTOMER_PREPAYMENT' : 'RECEIVABLE',
      'items': <Object>[],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('attachments')) fileQueries.add(query ?? {});
    return const [];
  }
}
