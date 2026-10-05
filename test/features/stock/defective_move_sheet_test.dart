// ADR-146 不良品处置面板：调出/调入仓按用途只能选对应类别的子仓，必须写原因，
// 提交一次建单并过账；失败重试沿用同一个提交键，不会重复过账；结果未知时内容锁定只能原样重试；
// 服务端列出的「转走后已经没有实物的预留」提醒办理人。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/stock/repositories/defective_move_repository.dart';
import 'package:uten_imp/features/stock/widgets/defective_move_sheet.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

const _hierarchy = [
  WarehouseDictEntry(id: 'root', name: '仓库(14年版)', code: '001'),
  WarehouseDictEntry(
    id: 'good',
    name: '包材仓库',
    code: 'XW02',
    parentId: 'root',
    selectableForNew: true,
  ),
  WarehouseDictEntry(
    id: 'good2',
    name: '五金仓库',
    code: 'C01',
    parentId: 'root',
    selectableForNew: true,
  ),
  WarehouseDictEntry(
    id: 'bad',
    name: '成品不良品仓',
    code: 'C0401',
    parentId: 'root',
    isDefective: true,
    selectableDefective: true,
  ),
];

class _Names extends MasterNameService {
  _Names() : super(ApiClient(Dio()));
  @override
  Future<void> ensureWarehousesLoaded() async {}
  @override
  List<WarehouseDictEntry> get warehouseHierarchy => _hierarchy;
  @override
  String warehouse(String? id) =>
      _hierarchy.where((entry) => entry.id == id).firstOrNull?.name ?? '';
}

class _Repo extends DefectiveMoveRepository {
  _Repo({this.failures = 0, this.failureStatus, this.warnings = const []})
    : super(ApiClient(Dio()));
  int failures;
  final int? failureStatus;
  final List<String> warnings;
  final calls = <Map<String, Object?>>[];

  @override
  Future<DefectiveMoveResult> create({
    required String kind,
    required String fromWarehouseId,
    required String toWarehouseId,
    required String reason,
    required String requestKey,
    required String goodsId,
    String? colorId,
    String? unitId,
    required double qty,
  }) async {
    calls.add({
      'kind': kind,
      'from': fromWarehouseId,
      'to': toWarehouseId,
      'reason': reason,
      'requestKey': requestKey,
      'goodsId': goodsId,
      'unitId': unitId,
      'qty': qty,
    });
    if (failures-- > 0) {
      throw ApiException(
        failureStatus == null ? 'NETWORK' : 'VALIDATION_FAILED',
        failureStatus == null ? '网络中断, 请重试' : '调出仓库存不足',
        httpStatus: failureStatus,
      );
    }
    return DefectiveMoveResult(billNo: 'CB20261004000001', warnings: warnings);
  }
}

Future<(ProviderContainer, ValueNotifier<bool?>)> _open(
  WidgetTester tester,
  _Repo repo, {
  String kind = DefectiveMoveKind.toDefective,
  String? from,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      masterNameServiceProvider.overrideWithValue(_Names()),
      defectiveMoveRepositoryProvider.overrideWithValue(repo),
    ],
  );
  addTearDown(container.dispose);
  final result = ValueNotifier<bool?>(null);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result.value = await showDefectiveMoveSheet(
                    context,
                    kind: kind,
                    goodsId: 'goods-1',
                    goodsName: '端子',
                    unitId: 'unit-1',
                    unitName: '个',
                    fromWarehouseId: from,
                  ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return (container, result);
}

Future<void> _pickTo(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(const Key('defective-move-to')));
  await tester.pumpAndSettle();
  // 先显示主仓，点进主仓再选子仓。
  await tester.tap(find.byKey(const Key('warehouse-picker-entry-root')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('warehouse-picker-entry-$id')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('to-defective only offers defective targets and posts once', (
    tester,
  ) async {
    final repo = _Repo();
    final (container, result) = await _open(tester, repo, from: 'good');

    // 调出仓从余额行带入(良品仓)。
    expect(
      find.descendant(
        of: find.byKey(const Key('defective-move-from')),
        matching: find.text('包材仓库'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('defective-move-to')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-root')));
    await tester.pumpAndSettle();
    // 转不良品仓的调入仓只列不良品仓，并带「不良品」标签；良品仓不出现。
    expect(find.byKey(const Key('warehouse-picker-entry-bad')), findsOneWidget);
    expect(
      find.byKey(const Key('warehouse-picker-defective-bad')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('warehouse-picker-entry-good2')), findsNothing);
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-bad')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('defective-move-qty')),
        matching: find.byType(EditableText),
      ),
      '3',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('defective-move-reason')),
        matching: find.byType(EditableText),
      ),
      '外观划伤, 判不良',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('defective-move-submit')));
    await tester.pumpAndSettle();

    expect(repo.calls, hasLength(1));
    expect(repo.calls.single, containsPair('kind', 'TO_DEFECTIVE'));
    expect(repo.calls.single, containsPair('from', 'good'));
    expect(repo.calls.single, containsPair('to', 'bad'));
    expect(repo.calls.single, containsPair('qty', 3.0));
    expect(repo.calls.single, containsPair('reason', '外观划伤, 判不良'));
    expect(result.value, isTrue);
    expect(
      container.read(appNotificationProvider).map((n) => n.message),
      contains('已过账: CB20261004000001'),
    );
  });

  testWidgets('release starts from a defective warehouse and returns to good', (
    tester,
  ) async {
    final repo = _Repo();
    // 从良品仓行误开「复判转回」时不带入调出仓(只有不良品仓能当调出仓)。
    await _open(tester, repo, kind: DefectiveMoveKind.release, from: 'good');
    expect(
      find.descendant(
        of: find.byKey(const Key('defective-move-from')),
        matching: find.text('包材仓库'),
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('defective-move-from')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-root')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('warehouse-picker-entry-good')), findsNothing);
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-bad')));
    await tester.pumpAndSettle();
    await _pickTo(tester, 'good2');
    expect(
      find.descendant(
        of: find.byKey(const Key('defective-move-to')),
        matching: find.text('五金仓库'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('missing reason is refused locally and a retry reuses the key', (
    tester,
  ) async {
    final repo = _Repo(failures: 1);
    final (container, _) = await _open(tester, repo, from: 'good');
    await _pickTo(tester, 'bad');
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('defective-move-qty')),
        matching: find.byType(EditableText),
      ),
      '2',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('defective-move-submit')));
    await tester.pumpAndSettle();
    expect(repo.calls, isEmpty, reason: '没写原因不提交');
    expect(
      container.read(appNotificationProvider).map((n) => n.message),
      contains('请选好调出仓、调入仓, 填写大于 0 的数量和原因'),
    );

    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('defective-move-reason')),
        matching: find.byType(EditableText),
      ),
      '包装破损',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('defective-move-submit')));
    await tester.pumpAndSettle();
    // 发出后结果未知: 内容锁定, 只能按原内容重试(同一个提交键)。
    expect(find.byKey(const Key('defective-move-uncertain')), findsOneWidget);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('defective-move-qty')),
              matching: find.byType(EditableText),
            ),
          )
          .readOnly,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('defective-move-submit')));
    await tester.pumpAndSettle();
    expect(repo.calls, hasLength(2));
    expect(repo.calls[0]['requestKey'], repo.calls[1]['requestKey']);
    expect(repo.calls[0]['qty'], repo.calls[1]['qty']);
    expect(
      container.read(appNotificationProvider).map((n) => n.message),
      contains('网络中断, 请重试'),
    );
  });

  testWidgets('a definite refusal keeps the fields editable', (tester) async {
    final repo = _Repo(failures: 1, failureStatus: 422);
    await _open(tester, repo, from: 'good');
    await _pickTo(tester, 'bad');
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('defective-move-qty')),
        matching: find.byType(EditableText),
      ),
      '9',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('defective-move-reason')),
        matching: find.byType(EditableText),
      ),
      '尺寸超差',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('defective-move-submit')));
    await tester.pumpAndSettle();
    // 服务端明确拒绝 = 什么都没办: 不锁定, 可以改数后再提交。
    expect(find.byKey(const Key('defective-move-uncertain')), findsNothing);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('defective-move-qty')),
        matching: find.byType(EditableText),
      ),
      '3',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('defective-move-submit')));
    await tester.pumpAndSettle();
    expect(repo.calls, hasLength(2));
    expect(repo.calls.last['qty'], 3.0);
  });

  testWidgets('reservations left without stock are shown to the operator', (
    tester,
  ) async {
    const warning =
        '「包材仓库」的端子还有 10 已被预留(订单、生产或备料), 转走后这个仓只剩 7, '
        '有 3 的预留已经没有实物; 请通知计划员或业务员重新安排';
    final repo = _Repo(warnings: const [warning]);
    final (container, result) = await _open(tester, repo, from: 'good');
    await _pickTo(tester, 'bad');
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('defective-move-qty')),
        matching: find.byType(EditableText),
      ),
      '3',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('defective-move-reason')),
        matching: find.byType(EditableText),
      ),
      '外观划伤',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('defective-move-submit')));
    await tester.pumpAndSettle();
    expect(result.value, isTrue);
    final messages = container
        .read(appNotificationProvider)
        .map((n) => n.message)
        .toList();
    expect(messages, contains('已过账: CB20261004000001'));
    expect(messages, contains(warning));
  });
}
