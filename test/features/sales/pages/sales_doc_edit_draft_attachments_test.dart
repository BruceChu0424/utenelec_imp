import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

/// 新建销售订货单：保存前就有附件暂存区（G4），已有订单仍用即时上传区。
void main() {
  tearDown(() => FilePicker.platform = _Picker(const []));

  testWidgets(
    'new order shows the draft attachment area and lists picked files as pending',
    (tester) async {
      final picker = _Picker([
        PlatformFile(
          name: '销售合同.pdf',
          size: 6,
          bytes: Uint8List.fromList('%PDF-1'.codeUnits),
        ),
      ]);
      FilePicker.platform = picker;
      final files = _Files();
      await _pumpEditor(tester, files, type: SalesDocType.order);

      final draft = find.byKey(const ValueKey('sales-order-draft-attachments'));
      expect(draft, findsOneWidget);
      expect(find.byType(PendingAttachmentSection), findsOneWidget);
      expect(find.text('添加文件'), findsOneWidget);
      expect(find.text('上传'), findsNothing, reason: '没有 UUID 前不能即时上传');

      // 上传前不问分类：没有分类芯片，也没有那句暂存提示语。
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.textContaining('保存单据后自动上传'), findsNothing);
      expect(find.textContaining('保存前可随时移除'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('pending-attachment-add')));
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(find.text('销售合同.pdf'), findsOneWidget);
      expect(find.textContaining('待保存后上传'), findsOneWidget);
      expect(files.uploads, isEmpty, reason: '保存前绝不调用 presign/confirm');
      final section = tester.widget<BusinessAttachmentSection>(draft);
      expect(section.isDraft, isTrue);
      expect(section.draftController!.items.single.name, '销售合同.pdf');
      expect(section.draftController!.items.single.category, isNull);

      // 分类在文件旁边可选设置：点「＋分类」→ 选一个 → 只改这一行。
      await tester.tap(find.text('分类'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '客户确认'),
      );
      await tester.pumpAndSettle();
      expect(section.draftController!.items.single.category, '客户确认');
      expect(files.uploads, isEmpty, reason: '设置分类不提前触发上传');
    },
  );

  testWidgets('new order without create permission has no draft area', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      _Files(),
      type: SalesDocType.order,
      permissions: const {Perm.attachmentUpload, Perm.attachmentView},
    );
    expect(
      find.byKey(const ValueKey('sales-order-draft-attachments')),
      findsOneWidget,
    );
    expect(find.text('添加文件'), findsNothing);
  });

  testWidgets('existing order keeps the live attachment area bound to its id', (
    tester,
  ) async {
    final files = _Files();
    await _pumpEditor(
      tester,
      files,
      type: SalesDocType.order,
      id: 'order-1',
      detail: const {
        'id': 'order-1',
        'billNo': 'XD202609100001',
        'billDate': '2026-09-10',
        'status': 0,
        'writable': true,
        'clientId': 'client-1',
        'currencyId': 'currency-usd',
        'settlementMethodId': 'settlement-net30',
        'taxRate': 13,
        'sellerId': 'seller-1',
        'deliverDate': '2026-09-20',
        'shipmentPolicy': 'ALLOW_PARTIAL',
        'items': <Map<String, dynamic>>[],
      },
    );
    expect(
      find.byKey(const ValueKey('sales-order-draft-attachments')),
      findsNothing,
    );
    final section = tester.widget<BusinessAttachmentSection>(
      find.byType(BusinessAttachmentSection),
    );
    expect(section.isDraft, isFalse);
    expect(section.ownerType, 'SALES_ORDER');
    expect(section.ownerId, 'order-1');
    expect(files.listed, [('SALES_ORDER', 'order-1')]);
  });

  testWidgets('non-order sales documents have no attachment area', (
    tester,
  ) async {
    await _pumpEditor(tester, _Files(), type: SalesDocType.quote);
    expect(find.byType(BusinessAttachmentSection), findsNothing);
  });
}

Future<void> _pumpEditor(
  WidgetTester tester,
  _Files files, {
  required SalesDocType type,
  String? id,
  Map<String, dynamic>? detail,
  Set<String> permissions = const {
    Perm.attachmentView,
    Perm.attachmentUpload,
    Perm.attachmentDelete,
    Perm.salesOrderCreate,
    Perm.salesOrderEdit,
  },
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final api = _EditorApi(detail);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        attachmentServiceProvider.overrideWithValue(files),
        currentPermissionsProvider.overrideWithValue(permissions),
        sharedPreferencesProvider.overrideWithValue(preferences),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        sessionProvider.overrideWith(_TestSessionNotifier.new),
      ],
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: GoRouter(
          initialLocation: '/edit',
          routes: [
            GoRoute(
              path: '/edit',
              builder: (_, _) => SalesDocEditPage(docType: type, id: id),
            ),
            GoRoute(
              path: '/:rest(.*)',
              builder: (_, _) => const SizedBox.shrink(),
            ),
          ],
        ),
        builder: (context, child) => Stack(
          children: [
            Positioned.fill(child: child!),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppNotificationHost(),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _EditorApi extends ApiClient {
  _EditorApi(this.detail) : super(Dio());

  final Map<String, dynamic>? detail;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (detail != null && path.endsWith('/${detail!['id']}')) {
      return detail!;
    }
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 1,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

class _Files extends AttachmentService {
  _Files() : super(ApiClient(Dio()));
  final listed = <(String type, String id)>[];
  final uploads = <String>[];

  @override
  Future<List<Attachment>> list({
    required String ownerType,
    required String ownerId,
  }) async {
    listed.add((ownerType, ownerId));
    return const [];
  }

  @override
  Future<Attachment> upload({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
    String? category,
  }) async {
    uploads.add('$ownerType/$ownerId/$fileName');
    throw StateError('not expected during this test');
  }
}

class _Picker extends FilePicker {
  _Picker(this.files);
  final List<PlatformFile> files;
  int calls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    return FilePickerResult(files);
  }
}
