import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/features/quality/models/production_fqc_inspection.dart';
import 'package:uten_imp/features/quality/repositories/production_fqc_repository.dart';
import 'package:uten_imp/features/quality/widgets/production_fqc_dialogs.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Fqc extends ProductionFqcRepository {
  _Fqc(this.status) : super(ApiClient(Dio()));
  final String status;
  @override
  Future<ProductionFqcInspection> detail(String id) async =>
      ProductionFqcInspection.fromJson({
        'id': id,
        'status': status,
        'reportedQty': 10,
        'passedQty': status == 'PARTIAL' ? 5 : 0,
        'failedQty': 0,
        'remainingQty': status == 'PENDING' ? 10 : 5,
      });
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Set<String> permissions = const {
      Perm.goodsView,
      Perm.goodsEdit,
      Perm.productionQualityInspectionView,
      Perm.productionQualityInspectionApprove,
      Perm.attachmentView,
      Perm.attachmentUpload,
      Perm.attachmentDelete,
    },
    String status = 'PENDING',
  }) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1100, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(permissions),
          isSuperAdminProvider.overrideWithValue(false),
          colorDictProvider.overrideWith((ref) async => const []),
          unitDictProvider.overrideWith((ref) async => const []),
          businessAttachmentsProvider.overrideWith(
            (ref, owner) async => const [],
          ),
          productionFqcRepositoryProvider.overrideWithValue(_Fqc(status)),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget goods({
    bool saved = true,
    bool edit = true,
    bool writable = true,
    bool actions = false,
  }) => GoodsDetailBody(
    initialDetail: saved
        ? GoodsDetail(id: 'goods-a', name: '测试货品', writable: writable)
        : null,
    initialCategoryId: null,
    initialTab: 0,
    canCreate: true,
    canEdit: edit,
    canStatus: actions,
    canBomCreate: false,
    canBomEdit: false,
    canBomDelete: false,
    onToggleStatus: actions ? () {} : null,
    onDelete: actions ? () {} : null,
    onViewMovements: null,
    onDataChanged: null,
  );

  testWidgets(
    'saved goods adds files after existing tabs with public document categories',
    (tester) async {
      await pump(tester, goods(actions: true));
      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('启用'), findsOneWidget);
      final tabs = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabs.tabs.cast<Tab>().map((tab) => tab.text), [
        '基本信息',
        '组装信息',
        '图片和文件',
      ]);
      await tester.tap(find.text('图片和文件'));
      await tester.pumpAndSettle();
      final files = tester.widget<AttachmentSection>(
        find.byType(AttachmentSection),
      );
      expect(files.ownerType, 'GOODS');
      expect(files.ownerId, 'goods-a');
      expect(files.categories, ['产品图片', '图纸', '规格资料']);
      expect(find.text('上传'), findsOneWidget);
      expect(find.textContaining('请不要放入价格、成本'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unsaved goods has no file binding or upload entry', (
    tester,
  ) async {
    await pump(tester, goods(saved: false));
    expect(find.text('图片和文件'), findsNothing);
    expect(find.byType(BusinessAttachmentSection), findsNothing);
  });

  testWidgets('read-only goods keeps documents readable but cannot upload', (
    tester,
  ) async {
    await pump(tester, goods(edit: false));
    await tester.tap(find.text('图片和文件'));
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentSection), findsOneWidget);
    expect(find.text('上传'), findsNothing);
  });

  testWidgets('without file permission goods hides the entire file tab', (
    tester,
  ) async {
    await pump(tester, goods(), permissions: {Perm.goodsView, Perm.goodsEdit});
    expect(find.text('图片和文件'), findsNothing);
  });

  testWidgets(
    'read-only delegated goods does not expose edits or file mutation',
    (tester) async {
      await pump(tester, goods(writable: false, actions: true));
      expect(find.text('编辑'), findsNothing);
      expect(find.text('删除'), findsNothing);
      expect(find.text('启用'), findsNothing);
      await tester.tap(find.text('图片和文件'));
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentSection), findsOneWidget);
      expect(find.text('上传'), findsNothing);
      expect(GoodsDetail.fromJson({'id': 'legacy-goods'}).writable, isFalse);
    },
  );

  for (final status in ['PENDING', 'PARTIAL', 'RESOLVED', 'CANCELLED']) {
    testWidgets('FQC $status evidence follows first-decision freeze', (
      tester,
    ) async {
      await pump(
        tester,
        const ProductionFqcDetailDialog(
          inspectionId: 'inspection-a',
          canApprove: true,
        ),
        status: status,
      );
      final files = tester.widget<AttachmentSection>(
        find.byType(AttachmentSection),
      );
      expect(files.ownerType, 'PRODUCTION_QUALITY_INSPECTION');
      expect(files.ownerId, 'inspection-a');
      expect(files.ownerCanUpload, status == 'PENDING');
      expect(files.ownerCanDelete, status == 'PENDING');
      expect(
        find.text('上传'),
        status == 'PENDING' ? findsOneWidget : findsNothing,
      );
      expect(find.textContaining('登记结果后（包括部分检验）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('FQC view-only staff cannot change even pending evidence', (
    tester,
  ) async {
    await pump(
      tester,
      const ProductionFqcDetailDialog(
        inspectionId: 'inspection-a',
        canApprove: false,
      ),
    );
    expect(find.byType(AttachmentSection), findsOneWidget);
    expect(find.text('上传'), findsNothing);
  });

  testWidgets('current action permissions override earlier edit capabilities', (
    tester,
  ) async {
    const permissions = {
      Perm.goodsView,
      Perm.productionQualityInspectionView,
      Perm.attachmentView,
      Perm.attachmentUpload,
      Perm.attachmentDelete,
    };
    await pump(tester, goods(), permissions: permissions);
    await tester.tap(find.text('图片和文件'));
    await tester.pumpAndSettle();
    expect(find.text('上传'), findsNothing);
    await pump(
      tester,
      const ProductionFqcDetailDialog(
        inspectionId: 'inspection-a',
        canApprove: true,
      ),
      permissions: permissions,
    );
    expect(find.text('上传'), findsNothing);
  });
}
