// 新建采购订货单「勾选口径」测试（2026-09-17 用户口径）：
//   1. 任务中心带单进入 → 明细行默认全选（保存只认勾选行，默认全选=旧行为不变）；
//   2. 全部取消勾选 → 右下「保存」置灰，灰态点击说明原因（没选不给点）；
//   3. 只勾一部分保存 → 先弹「有 N 行未勾选」确认，确认后行级校验只针对
//      勾选行（未勾选行不进本次提交集，不参与校验也不生成订货）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/purchase/pages/purchase_order_edit_page.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets('带单进入默认全选；取消全部勾选后保存置灰并说明原因；部分勾选只校验勾选行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_SelectionApi()),
          sessionProvider.overrideWith(_EmptySessionNotifier.new),
        ],
        child: const MaterialApp(
          home: Column(
            children: [
              AppNotificationHost(),
              Expanded(
                child: PurchaseOrderEditPage(
                  sourceRequestItemIds: ['it-1', 'it-2'],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 预填两行（两个货品）默认全选：两行复选框 + 表头全选框（树序：行框在前）。
    final checkboxes = find.byType(Checkbox);
    expect(checkboxes, findsNWidgets(3));
    expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isTrue);
    expect(tester.widget<Checkbox>(checkboxes.at(1)).value, isTrue);
    expect(tester.widget<Checkbox>(checkboxes.at(2)).value, isTrue);

    // 有勾选行 → 保存可点。
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

    // 只勾第一行保存：有货品却未勾选的行先经确认，确认后校验只报勾选行。
    await tester.tap(checkboxes.at(0));
    await tester.pump();
    expect(saveButton().onPressed, isNotNull);
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('有 1 行明细未勾选'), findsOneWidget);
    await tester.tap(find.text('只提交勾选行'));
    await tester.pumpAndSettle();
    // 勾选行缺供应商/结账方式/币种 → 校验报「第 1 行」；未勾选的第二行不出现。
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
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async {
    if (path.contains('decomposition-preview')) {
      return const [
        {
          'sourceDocumentId': 'req-1',
          'sourceDocumentNo': 'CG-SQ-20260917-001',
          'sourceItemId': 'it-1',
          'goodsId': 'g-1',
          'requestedQty': 10,
          'orderedQty': 0,
          'pendingQty': 0,
          'remainingQty': 10,
          'colorId': 'c-1',
          'unitId': 'u-1',
          'needDate': '2026-09-20',
        },
        {
          'sourceDocumentId': 'req-1',
          'sourceDocumentNo': 'CG-SQ-20260917-001',
          'sourceItemId': 'it-2',
          'goodsId': 'g-2',
          'requestedQty': 5,
          'orderedQty': 0,
          'pendingQty': 0,
          'remainingQty': 5,
          'colorId': 'c-2',
          'unitId': 'u-1',
          'needDate': '2026-09-20',
        },
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('last-terms')) return const {};
    if (path.contains('/master/suppliers')) {
      return const {
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'size': 20,
        'total': 0,
        'totalPages': 0,
      };
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
  }) async {
    if (path.contains('/master/suppliers/dict')) {
      return const [
        {'id': 's1', 'code': 'GY001', 'name': '洪武五金', 'status': '使用'},
      ];
    }
    return const [];
  }
}
