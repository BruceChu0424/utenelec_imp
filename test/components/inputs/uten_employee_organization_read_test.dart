import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/models/department_node.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'closing an owned organization read cancels it; reopening reads once',
    (tester) async {
      final adapter = _OrganizationAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final api = ApiClient(dio);
      Future<List<DepartmentNode>> load() async => (await api.getList(
        '/owned/departments',
      )).map(DepartmentNode.fromJson).toList();

      await tester.pumpWidget(_panel(load, owned: true));
      await _requests(tester, adapter, 1);
      expect(adapter.requests, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 60));
      expect(adapter.cancelled, [true]);

      await tester.pumpWidget(_panel(load, owned: true));
      await _requests(tester, adapter, 2);
      expect(adapter.requests, hasLength(2));
      adapter.respond(1, 'new', '新部门');
      adapter.respond(0, 'old', '旧部门');
      await tester.pumpAndSettle();
      expect(find.text('新部门'), findsOneWidget);
      expect(find.text('旧部门'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a shared organization future survives one consumer closing', (
    tester,
  ) async {
    final adapter = _OrganizationAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final api = ApiClient(dio);
    Future<List<DepartmentNode>>? shared;
    Future<List<DepartmentNode>> read() async => (await api.getList(
      '/shared/departments',
    )).map(DepartmentNode.fromJson).toList();
    Future<List<DepartmentNode>> load() => shared ??= read();

    await tester.pumpWidget(_panel(load));
    await _requests(tester, adapter, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 60));
    expect(adapter.cancelled, [false]);
    await tester.pumpWidget(_panel(load));
    await _requests(tester, adapter, 1);
    expect(adapter.requests, hasLength(1));
    adapter.respond(0, 'shared', '共用部门');
    await tester.pumpAndSettle();
    expect(find.text('共用部门'), findsOneWidget);
    expect(adapter.cancelled, [false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing the business scope retires only its owned tree read', (
    tester,
  ) async {
    final adapter = _OrganizationAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final api = ApiClient(dio);
    Future<List<DepartmentNode>> load() async => (await api.getList(
      '/scope/departments',
    )).map(DepartmentNode.fromJson).toList();

    await tester.pumpWidget(_panel(load, owned: true));
    await _requests(tester, adapter, 1);
    await tester.pumpWidget(_panel(load, owned: true, scope: 'b'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(adapter.requests, hasLength(2));
    expect(adapter.cancelled, [true, false]);
    adapter.respond(0, 'old', '旧范围');
    adapter.respond(1, 'new', '当前范围');
    await tester.pumpAndSettle();
    expect(find.text('当前范围'), findsOneWidget);
    expect(find.text('旧范围'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _requests(
  WidgetTester tester,
  _OrganizationAdapter adapter,
  int count,
) async {
  for (
    var attempt = 0;
    attempt < 20 && adapter.requests.length < count;
    attempt++
  ) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(adapter.requests, hasLength(count));
}

Widget _panel(
  Future<List<DepartmentNode>> Function() load, {
  bool owned = false,
  String scope = 'a',
}) => MaterialApp(
  home: Scaffold(
    body: UtenEmployeeSelectionPanel(
      candidateScopeKey: scope,
      departmentTreeLoader: load,
      cancelDepartmentTreeReadOnClose: owned,
      pagedLoader: (_) async => const UtenEmployeePickerPage.empty(),
    ),
  ),
);

class _OrganizationAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final cancelled = <bool>[];
  final _pending = <Completer<ResponseBody>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final index = requests.length;
    requests.add(options);
    cancelled.add(false);
    final pending = Completer<ResponseBody>();
    _pending.add(pending);
    cancelFuture?.then((_) => cancelled[index] = true);
    return pending.future;
  }

  void respond(int index, String id, String name) => _pending[index].complete(
    ResponseBody.fromString(
      jsonEncode([
        {
          'id': id,
          'code': id,
          'name': name,
          'level': '一级部门',
          'children': <Map<String, dynamic>>[],
        },
      ]),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    ),
  );

  @override
  void close({bool force = false}) {}
}
