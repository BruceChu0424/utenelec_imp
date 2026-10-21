import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/platform_tables/platform_row_draft.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';

const _own = PlatformColumnDefinition(
  id: 'own',
  scope: 'resource',
  name: '我的包装说明',
  canDelete: true,
);
const _other = PlatformColumnDefinition(
  id: 'other',
  scope: 'resource',
  name: '同事的说明',
);
const _capabilities = PlatformTableCapabilities(
  scope: 'resource',
  canWrite: true,
  canDefine: true,
);
const _layout = PlatformTableLayout(
  added: [_own, _other],
  order: ['name', 'platform:own', 'platform:other'],
  hidden: {'code'},
  pinned: {'name', 'platform:own'},
  widths: {'name': 180, 'platform:own': 240, 'platform:other': 150},
  filters: {
    'name': '货品',
    'platform:own': '包装',
    'search.platform:own': '箱',
    'platform:other': '备注',
  },
  sortColumn: 'platform:own',
  sortAscending: false,
  hasQueryPreferences: true,
);

class _Repository extends PlatformTableRepository {
  _Repository() : super(ApiClient(Dio()));
  final deletes = <String>[];
  Completer<void>? gate;
  bool fail = false;

  @override
  Future<void> deleteDefinition(String scope, String id) async {
    deletes.add('$scope/$id');
    await gate?.future;
    if (fail) throw const FormatException('列仍被计算公式引用');
  }
}

class _Controller extends PlatformTableController<String> {
  _Controller(_Repository repo) {
    repository = repo;
    binding = PlatformTableBinding<String>(
      tableKey: 'test.column-deletion',
      scope: 'resource',
      recordIdOf: (row) => row,
      canEditValues: true,
    );
    capabilities = _capabilities;
    updateLayout(_layout);
  }

  bool editing = true;
  int revision = 0;
  @override
  bool get columnEditingEnabled => editing && !historical;
  @override
  int get authorizationRevision => revision;
}

void main() {
  test('删除能力只接受本次服务端元数据，不写入布局和草稿缓存', () {
    expect(_own.canDelete, isTrue);
    expect(_other.canDelete, isFalse);
    expect(
      PlatformColumnDefinition.fromJson({
        ..._other.toJson(),
        'canDelete': true,
      }).canDelete,
      isTrue,
    );
    expect(
      PlatformColumnDefinition.fromJson({
        ..._other.toJson(),
        'canDelete': 'true',
      }).canDelete,
      isFalse,
    );
    expect(_own.toJson().containsKey('canDelete'), isFalse);
    expect(
      PlatformTableLayout.fromJson(_layout.toJson()).added.first.canDelete,
      isFalse,
    );
  });

  test('仓库使用定义删除接口发送一次 DELETE', () async {
    final dio = Dio();
    final requests = <RequestOptions>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<void>(requestOptions: options, statusCode: 204),
          );
        },
      ),
    );
    await PlatformTableRepository(
      ApiClient(dio),
    ).deleteDefinition('resource', 'own');
    expect(requests, hasLength(1));
    expect(requests.single.method, 'DELETE');
    expect(requests.single.path, '/platform-columns/resource/definitions/own');
  });

  test('服务器删除成功后清理列布局和查询，保留历史值与版本且防止重复请求', () async {
    final repository = _Repository()..gate = Completer<void>();
    final controller = _Controller(repository);
    addTearDown(controller.dispose);
    final draft = PlatformRowDraft()
      ..adopt(
        const PlatformRowValues(
          recordId: 'record',
          version: 7,
          canWrite: true,
          cells: [
            PlatformColumnCell(
              columnId: 'own',
              definition: _own,
              value: '历史包装值',
            ),
          ],
        ),
      );
    addTearDown(draft.dispose);
    controller.draftOf = (_) => draft;
    final stored = draft.exportDraft();
    final pending = controller.deleteColumn(_own);
    expect(repository.deletes, ['resource/own']);
    expect(controller.layout.toJson(), _layout.toJson());
    await expectLater(controller.deleteColumn(_own), throwsFormatException);
    expect(repository.deletes, ['resource/own']);
    repository.gate!.complete();
    await pending;
    expect(controller.layout.added, [_other]);
    expect(controller.layout.order, ['name', 'platform:other']);
    expect(controller.layout.hidden, {'code', 'platform:own'});
    expect(controller.layout.pinned, {'name'});
    expect(controller.layout.widths, {'name': 180, 'platform:other': 150});
    expect(controller.layout.filters, {'name': '货品', 'platform:other': '备注'});
    expect(controller.layout.sortColumn, isNull);
    expect(controller.layout.hasQueryPreferences, isTrue);
    expect(controller.value('record', _own), '历史包装值');
    expect(draft.exportDraft(), stored);
  });

  test('服务器拒绝删除时所有布局和历史数据保持原样', () async {
    final repository = _Repository()..fail = true;
    final controller = _Controller(repository);
    addTearDown(controller.dispose);
    await expectLater(controller.deleteColumn(_own), throwsFormatException);
    expect(repository.deletes, ['resource/own']);
    expect(controller.layout.toJson(), _layout.toJson());
    repository.fail = false;
    await controller.deleteColumn(_own);
    expect(repository.deletes, ['resource/own', 'resource/own']);
    expect(controller.layout.added, [_other]);
  });

  test('删除目录源列后已保存值与个人公式的计算结果继续保留', () async {
    const source = PlatformColumnDefinition(
      id: 'source',
      scope: 'resource',
      name: '单箱重量',
      type: 'NUMBER',
      canDelete: true,
    );
    const calculation = PlatformColumnDefinition(
      id: 'display-calculation',
      scope: '',
      name: '两箱参考重量',
      type: 'CALCULATED',
      formula: PlatformFormula(
        base: PlatformFormulaOperand(columnId: 'source'),
        steps: [
          PlatformFormulaStep(
            operation: 'MULTIPLY',
            operand: PlatformFormulaOperand(constant: '2'),
          ),
        ],
      ),
    );
    final repository = _Repository();
    final controller = _Controller(repository);
    addTearDown(controller.dispose);
    controller.updateLayout(const PlatformTableLayout(added: [calculation]));
    controller.rememberCatalogResults([source]);
    final draft = PlatformRowDraft()
      ..adopt(
        const PlatformRowValues(
          recordId: 'record',
          version: 7,
          canWrite: true,
          cells: [
            PlatformColumnCell(
              columnId: 'source',
              definition: source,
              value: '12.5',
            ),
          ],
        ),
      );
    addTearDown(draft.dispose);
    controller.draftOf = (_) => draft;
    expect(controller.value('record', calculation), '25.0');
    await controller.deleteColumn(source);
    expect(repository.deletes, ['resource/source']);
    expect(controller.value('record', source), '12.5');
    expect(controller.value('record', calculation), '25.0');
    expect(controller.layout.added, [calculation]);
    expect(draft.version, 7);
  });

  test('个人计算列仅删除本地选择，引用中的个人源列不可先删除', () async {
    const local = PlatformColumnDefinition(
      id: 'display-source',
      scope: '',
      name: '个人参考',
      type: 'CALCULATED',
      formula: PlatformFormula(base: PlatformFormulaOperand(constant: '5')),
    );
    const dependent = PlatformColumnDefinition(
      id: 'display-dependent',
      scope: '',
      name: '引用个人参考',
      type: 'CALCULATED',
      formula: PlatformFormula(
        base: PlatformFormulaOperand(columnId: 'display-source'),
      ),
    );
    final repository = _Repository();
    final controller = _Controller(repository)
      ..binding = null
      ..repository = null;
    addTearDown(controller.dispose);
    controller.updateLayout(
      const PlatformTableLayout(added: [local, dependent]),
    );
    expect(controller.canDeleteColumn(local), isTrue);
    await expectLater(controller.deleteColumn(local), throwsFormatException);
    expect(controller.layout.added, [local, dependent]);
    await controller.deleteColumn(dependent);
    await controller.deleteColumn(local);
    expect(controller.layout.added, isEmpty);
    expect(controller.layout.hidden, {local.key, dependent.key});
    expect(controller.canDeleteColumn(local), isFalse);
    expect(repository.deletes, isEmpty);
  });

  test('删除某列保留其他列的排序与筛选', () async {
    final repository = _Repository();
    final controller = _Controller(repository);
    addTearDown(controller.dispose);
    controller.updateLayout(_layout.copyWith(sortColumn: 'platform:other'));
    await controller.deleteColumn(_own);
    expect(controller.layout.sortColumn, 'platform:other');
    expect(controller.layout.sortAscending, isFalse);
    expect(controller.layout.filters['platform:other'], '备注');
  });

  for (final boundary in [
    'repository',
    'scope',
    'authorization ABA',
    'permission',
    'edit mode',
    'dispose',
  ]) {
    test('$boundary 切换后不采纳旧删除回执', () async {
      final repository = _Repository()..gate = Completer<void>();
      final controller = _Controller(repository);
      addTearDown(() {
        if (!controller.disposed) controller.dispose();
      });
      final pending = controller.deleteColumn(_own);
      expect(repository.deletes, ['resource/own']);
      switch (boundary) {
        case 'repository':
          controller.repository = _Repository();
        case 'scope':
          controller.binding = controller.binding!.copyWith(scope: 'customer');
        case 'authorization ABA':
          controller.revision += 2;
        case 'permission':
          controller.capabilities = const PlatformTableCapabilities(
            scope: 'resource',
          );
        case 'edit mode':
          controller.editing = false;
        case 'dispose':
          controller.dispose();
      }
      repository.gate!.complete();
      await pending;
      expect(controller.layout.toJson(), _layout.toJson());
      expect(controller.layoutTouched, isTrue);
    });
  }

  for (final boundary in ['repository', 'authorization']) {
    test('$boundary 切换后的同列删除独立等待新请求，旧失败不释放新锁', () async {
      final firstGate = Completer<void>();
      final first = _Repository()..gate = firstGate;
      final controller = _Controller(first);
      addTearDown(controller.dispose);
      final oldRequest = controller.deleteColumn(_own);
      final oldFailure = expectLater(oldRequest, throwsFormatException);
      final secondGate = Completer<void>();
      late _Repository current;
      if (boundary == 'repository') {
        current = _Repository()..gate = secondGate;
        controller.repository = current;
      } else {
        current = first..gate = secondGate;
        controller.revision++;
      }
      final currentRequest = controller.deleteColumn(_own);
      expect(current.deletes.length, boundary == 'repository' ? 1 : 2);
      expect(controller.layout.toJson(), _layout.toJson());
      firstGate.completeError(const FormatException('旧账号删除失败'));
      await oldFailure;
      await expectLater(controller.deleteColumn(_own), throwsFormatException);
      expect(current.deletes.length, boundary == 'repository' ? 1 : 2);
      expect(controller.layout.toJson(), _layout.toJson());
      secondGate.complete();
      await currentRequest;
      expect(controller.layout.added, [_other]);
      expect(controller.layout.hidden, contains(_own.key));
    });
  }

  test('他人列、不同表、无定义权限与历史页面均不能直接删除', () async {
    final repository = _Repository();
    final controller = _Controller(repository);
    addTearDown(controller.dispose);
    expect(controller.canDeleteColumn(_own), isTrue);
    expect(controller.canDeleteColumn(_other), isFalse);
    await expectLater(controller.deleteColumn(_other), throwsFormatException);
    const foreign = PlatformColumnDefinition(
      id: 'foreign',
      scope: 'customer',
      name: '其他表的列',
      canDelete: true,
    );
    expect(controller.canDeleteColumn(foreign), isFalse);
    await expectLater(controller.deleteColumn(foreign), throwsFormatException);
    controller.capabilities = const PlatformTableCapabilities(
      scope: 'resource',
    );
    expect(controller.canDeleteColumn(_own), isFalse);
    await expectLater(controller.deleteColumn(_own), throwsFormatException);
    controller.capabilities = _capabilities;
    controller.binding = controller.binding!.copyWith(
      snapshotOf: (_) =>
          const PlatformRowValues(recordId: 'record', version: 1),
    );
    expect(controller.canDeleteColumn(_own), isFalse);
    await expectLater(controller.deleteColumn(_own), throwsFormatException);
    expect(repository.deletes, isEmpty);
    expect(controller.layout.toJson(), _layout.toJson());
  });
}
