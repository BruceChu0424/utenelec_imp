// 新建委外订货单（直下单/任务中心带单）「勾选口径」测试（2026-09-17 用户口径，
// 与采购订货单同款）：带单进入默认全选；全部取消勾选后保存置灰、灰态点击说明
// 原因；部分勾选保存先确认「有 N 行未勾选」，确认后校验只针对勾选行。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_order_edit_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
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

  // ADR-156：预填「这次可下单」(剩余与物料够做套数取小)，等物料齐套的明细不带入。
  testWidgets('带单只预填可下单数量；同货品合并加总，等物料齐套的明细不带入并说明', (tester) async {
    await _pumpPrefill(tester, const [
      SubcontractDecompositionLine(
        sourceDocumentId: 'app-1',
        sourceDocumentNo: 'WO-SQ-1',
        sourceItemId: 'it-1',
        goodsId: 'g-1',
        requestedQty: 10,
        orderedQty: 0,
        pendingQty: 0,
        remainingQty: 10,
        colorId: 'c-1',
        unitId: 'u-1',
        kitQty: 4,
        orderableQty: 4,
      ),
      SubcontractDecompositionLine(
        sourceDocumentId: 'app-1',
        sourceDocumentNo: 'WO-SQ-1',
        sourceItemId: 'it-2',
        goodsId: 'g-2',
        requestedQty: 5,
        orderedQty: 0,
        pendingQty: 0,
        remainingQty: 5,
        colorId: 'c-2',
        unitId: 'u-1',
        kitQty: 0,
        orderableQty: 0,
      ),
      SubcontractDecompositionLine(
        sourceDocumentId: 'app-2',
        sourceDocumentNo: 'WO-SQ-2',
        sourceItemId: 'it-3',
        goodsId: 'g-1',
        requestedQty: 3,
        orderedQty: 0,
        pendingQty: 0,
        remainingQty: 3,
        colorId: 'c-1',
        unitId: 'u-1',
        kitQty: 9,
        orderableQty: 3,
      ),
    ]);
    final rows = tester
        .widget<UtenEditableGrid<SubcontractGridRow>>(
          find.byType(UtenEditableGrid<SubcontractGridRow>),
        )
        .controller
        .rows;
    expect(rows, hasLength(1));
    expect(rows.single.goods?.id, 'g-1');
    expect(rows.single.qty.text, '7');
    // maxQty 仍记申请剩余量，只作来源参考。
    expect(rows.single.maxQty, 13);
    expect(rows.single.upstreamItemIds, ['it-1', 'it-3']);
    expect(
      find.textContaining('1 条申请明细的直属物料还没齐套，这次没带入；1 条只按现有物料够做的套数预填数量'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('所选申请全部等物料齐套时不预填并说明去看齐套情况', (tester) async {
    await _pumpPrefill(tester, const [
      SubcontractDecompositionLine(
        sourceDocumentId: 'app-1',
        sourceDocumentNo: 'WO-SQ-1',
        sourceItemId: 'it-1',
        goodsId: 'g-1',
        requestedQty: 10,
        orderedQty: 0,
        pendingQty: 0,
        remainingQty: 10,
        kitQty: 0,
        orderableQty: 0,
      ),
    ]);
    expect(
      find.text('所选委外申请的直属物料还没齐套，暂时不能下单；请返回委外任务中心查看「齐套情况」'),
      findsOneWidget,
    );
    final rows = tester
        .widget<UtenEditableGrid<SubcontractGridRow>>(
          find.byType(UtenEditableGrid<SubcontractGridRow>),
        )
        .controller
        .rows;
    expect(rows.where((row) => row.goods != null), isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('旧服务端不下发可下单数量时回落剩余量', () {
    final line = SubcontractDecompositionLine.fromJson({
      'sourceDocumentId': 'app-1',
      'sourceItemId': 'it-1',
      'goodsId': 'g-1',
      'remainingQty': 5,
    });
    expect(line.kitQty, isNull);
    expect(line.orderableQty, 5);
    final capped = SubcontractDecompositionLine.fromJson({
      'sourceDocumentId': 'app-1',
      'sourceItemId': 'it-1',
      'goodsId': 'g-1',
      'remainingQty': 5,
      'kitQty': '2.5',
      'orderableQty': 2.5,
    });
    expect(capped.kitQty, 2.5);
    expect(capped.orderableQty, 2.5);
  });
}

Future<void> _pumpPrefill(
  WidgetTester tester,
  List<SubcontractDecompositionLine> lines,
) async {
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
          _PreviewApplicationRepository(
            api,
            SubcontractDocType.application,
            lines: lines,
          ),
        ),
        sessionProvider.overrideWith(_EmptySessionNotifier.new),
      ],
      child: const MaterialApp(
        home: Column(
          children: [
            AppNotificationHost(),
            Expanded(
              child: SubcontractOrderEditPage(
                applicationItemIds: ['it-1', 'it-2', 'it-3'],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
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

/// 申请仓库只桩分解预览(默认两行两个货品)；其余走真实现 + 空 API。
class _PreviewApplicationRepository extends SubcontractRepository {
  _PreviewApplicationRepository(super.api, super.type, {this.lines});

  final List<SubcontractDecompositionLine>? lines;

  @override
  Future<List<SubcontractDecompositionLine>> decompositionPreview(
    Iterable<String> itemIds,
  ) async => lines ?? _defaultLines;
}

const _defaultLines = [
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
