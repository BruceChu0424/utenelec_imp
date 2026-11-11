import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';

const _note = PlatformColumnDefinition(
  id: 'persisted',
  scope: 'progressive',
  name: 'Saved supplement',
);

class _Layout extends PlatformTableLayoutNotifier {
  _Layout() : super('progressive.table');
  @override
  PlatformTableLayout build() => const PlatformTableLayout();
  @override
  void persist() {}
}

class _Repository extends PlatformTableRepository {
  _Repository() : super(ApiClient(Dio()));
  final gate = Completer<void>();
  final requests = <List<String>>[];
  int active = 0, peak = 0;
  @override
  Future<List<PlatformTableCapabilities>> scopes() async => [
    const PlatformTableCapabilities(scope: 'progressive'),
  ];
  @override
  Future<List<PlatformRowValues>> rows(
    String scope,
    List<String> ids, {
    List<String> columnIds = const [],
  }) async {
    requests.add(List.of(ids));
    active++;
    if (active > peak) peak = active;
    try {
      await gate.future;
      return [
        for (final id in ids)
          PlatformRowValues(
            recordId: id,
            version: 1,
            cells: [
              PlatformColumnCell(
                columnId: _note.id,
                definition: _note,
                value: 'saved-$id',
              ),
            ],
          ),
      ];
    } finally {
      active--;
    }
  }
}

void main() {
  testWidgets(
    'progressive records serialize current reads and retain persisted cells with no selected definitions',
    (tester) async {
      final repo = _Repository();
      final controller = PlatformTableController<String>();
      late BuildContext owner;
      addTearDown(() {
        if (!repo.gate.isCompleted) repo.gate.complete();
        controller.dispose();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            platformTableRepositoryProvider.overrideWithValue(repo),
            platformTableLayoutProvider(
              'progressive.table',
            ).overrideWith(_Layout.new),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                owner = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      var revision = 0;
      void configure(int count) => controller.configure(
        owner,
        descriptor: PlatformTableDescriptor<String>(
          kind: 'master',
          tableKey: 'progressive.table',
          columnKeys: const ['code'],
          revision: ++revision,
          rows: List.generate(count, (index) => 'record-$index'),
        ),
        explicitBinding: const PlatformTableBinding<String>(
          tableKey: 'progressive.table',
          scope: 'progressive',
          recordIdOf: _recordId,
        ),
      );
      configure(50);
      await tester.pump();
      expect(repo.requests, hasLength(1));
      final beforeValues = controller.valuesRevision;
      for (final count in [100, 200, 400, 800, 1626]) {
        configure(count);
        await tester.pump();
      }
      try {
        expect(
          controller.valuesRevision,
          beforeValues,
          reason:
              'queued generations and loading changes are not accepted values',
        );
        expect(
          repo.peak,
          1,
          reason:
              'one in-flight read plus the latest pending generation, not overlapping prefix requests',
        );
        repo.gate.complete();
        await tester.pumpAndSettle();
        expect(controller.loading, isFalse);
        expect(controller.error, isNull);
        expect(controller.valuesRevision, greaterThan(beforeValues));
        expect(repo.requests.last, hasLength(26));
        expect(
          repo.requests.skip(1).expand((ids) => ids).toList(),
          List.generate(1626, (index) => 'record-$index'),
        );
        expect(controller.value('record-1625', _note), 'saved-record-1625');
        expect(
          controller.definitions.map((column) => column.id),
          contains('persisted'),
        );
      } finally {
        if (!repo.gate.isCompleted) repo.gate.complete();
        await tester.pumpAndSettle();
      }
    },
  );
}

String _recordId(String row) => row;
