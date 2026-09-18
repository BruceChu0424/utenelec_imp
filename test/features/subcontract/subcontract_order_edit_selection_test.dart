// 新建委外订货单（直下单/任务中心带单）「勾选口径」测试（2026-09-17 用户口径，
// 与采购订货单同款）：带单进入默认全选；全部取消勾选后保存置灰、灰态点击说明
// 原因；部分勾选保存先确认「有 N 行未勾选」，确认后校验只针对勾选行。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_order_edit_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets('带单进入默认全选；取消全部勾选后保存置灰并说明原因；部分勾选只校验勾选行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _SelectionApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          subcontractRepositoryProvider(
            SubcontractDocType.application,
          ).overrideWithValue(
            _PreviewApplicationRepository(api, SubcontractDocType.application),
          ),
          sessionProvider.overrideWith(_EmptySessionNotifier.new),
        ],
        child: const MaterialApp(
          home: Column(
            children: [
              AppNotificationHost(),
              Expanded(
                child: SubcontractOrderEditPage(
                  applicationItemIds: ['it-1', 'it-2'],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 预填两行默认全选：两行复选框 + 表头全选框（树序：行框在前）。
    final checkboxes = find.byType(Checkbox);
    expect(checkboxes, findsNWidgets(3));
    expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isTrue);
    expect(tester.widget<Checkbox>(checkboxes.at(1)).value, isTrue);
    expect(tester.widget<Checkbox>(checkboxes.at(2)).value, isTrue);

    final save = find.byKey(const ValueKey('uten-edit-save'));
    UtenButton saveButton() => tester.widget<UtenButton>(save);
    expect(saveButton().onPressed, isNotNull);

    // 两行全部取消勾选 → 保存置灰；灰态点击给出原因。
    await tester.tap(checkboxes.at(0));
    await tester.pump();
    await tester.tap(checkboxes.at(1));
    await tester.pump();
    expect(saveButton().onPressed, isNull);
    await tester.tap(save);
    await tester.pump();
    expect(find.textContaining('请先在明细表勾选要生成订货的行'), findsOneWidget);

    // 只勾第一行保存：未勾选行先经确认，确认后校验只报勾选行。
    await tester.tap(checkboxes.at(0));
    await tester.pump();
    expect(saveButton().onPressed, isNotNull);
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('有 1 行明细未勾选'), findsOneWidget);
    await tester.tap(find.text('只提交勾选行'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 1 行'), findsWidgets);
    expect(find.textContaining('第 2 行'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _EmptySessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _SelectionApi extends ApiClient {
  _SelectionApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('last-terms')) return const {};
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
  }) async {
    if (path.contains('/master/suppliers/dict')) {
      return const [
        {'id': 's1', 'code': 'W001', 'name': '宁海外协', 'status': '使用'},
      ];
    }
    return const [];
  }
}

/// 申请仓库只桩分解预览（两行两个货品）；其余走真实现 + 空 API。
class _PreviewApplicationRepository extends SubcontractRepository {
  _PreviewApplicationRepository(super.api, super.type);

  @override
  Future<List<SubcontractDecompositionLine>> decompositionPreview(
    Iterable<String> itemIds,
  ) async => const [
    SubcontractDecompositionLine(
      sourceDocumentId: 'app-1',
      sourceDocumentNo: 'WO-SQ-20260917-001',
      sourceItemId: 'it-1',
      goodsId: 'g-1',
      requestedQty: 10,
      orderedQty: 0,
      pendingQty: 0,
      remainingQty: 10,
      colorId: 'c-1',
      unitId: 'u-1',
      needDate: '2026-09-20',
    ),
    SubcontractDecompositionLine(
      sourceDocumentId: 'app-1',
      sourceDocumentNo: 'WO-SQ-20260917-001',
      sourceItemId: 'it-2',
      goodsId: 'g-2',
      requestedQty: 5,
      orderedQty: 0,
      pendingQty: 0,
      remainingQty: 5,
      colorId: 'c-2',
      unitId: 'u-1',
      needDate: '2026-09-20',
    ),
  ];
}
