import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/platform_tables/platform_row_draft.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';

const _table = 'display-preference-repair';
const _record = 'b8f79439-8bd8-4468-8d17-e1e11da70ef6';
const _noteId = 'ef30ca09-54a5-49da-af9c-d5027825d28e';
const _note = PlatformColumnDefinition(
  id: _noteId,
  scope: 'goods',
  name: '包装说明',
);
const _malformed = PlatformColumnDefinition(
  id: 'old-column,not-a-uuid',
  scope: 'goods',
  name: '旧显示配置',
);

class _Layout extends PlatformTableLayoutNotifier {
  _Layout(this.initial) : super(_table);
  final PlatformTableLayout initial;
  @override
  PlatformTableLayout build() => initial;
  @override
  void persist() {}
}

void main() {
  for (final permissionHidden in [false, true]) {
    for (final includeValid in [true, false]) {
      final unavailable = PlatformColumnDefinition(
        id: _malformed.id,
        scope: _malformed.scope,
        name: _malformed.name,
        priceProtected: permissionHidden,
      );
      testWidgets(
        '${includeValid ? 'mixed' : 'all'} ${permissionHidden ? 'permission-hidden' : 'visible'} malformed saved display ids recover without changing drafts',
        (tester) async {
          final requests = <RequestOptions>[];
          final dio = Dio()
            ..interceptors.add(
              InterceptorsWrapper(
                onRequest: (request, handler) {
                  requests.add(request);
                  final Object data;
                  switch (request.path) {
                    case '/platform-columns/scopes':
                      data = [
                        {
                          'scope': 'goods',
                          'canWrite': true,
                          'priceVisible': false,
                        },
                      ];
                    case '/platform-columns/goods/definitions':
                      // Mirror the server transport contract: a malformed UUID
                      // must never reach Spring's List<UUID> query binding.
                      expect(request.queryParameters['ids'], _note.id);
                      expect(request.queryParameters['availableOnly'], isTrue);
                      data = [_note.toJson()];
                    case '/platform-columns/goods/values:batch':
                      final body = request.data as Map<String, dynamic>;
                      expect(body['recordIds'], [_record]);
                      expect(
                        body['columnIds'],
                        includeValid ? [_note.id] : isEmpty,
                      );
                      data = [
                        {
                          'recordId': _record,
                          'version': 8,
                          'canWrite': true,
                          'cells': [
                            {
                              'columnId': _note.id,
                              'definition': _note.toJson(),
                              'value': '服务端原值',
                            },
                          ],
                        },
                      ];
                    default:
                      fail(
                        'Unexpected request ${request.method} ${request.path}',
                      );
                  }
                  handler.resolve(
                    Response(requestOptions: request, data: data),
                  );
                },
              ),
            );
          final controller = PlatformTableController<String>();
          final draft = PlatformRowDraft()
            ..adopt(
              const PlatformRowValues(
                recordId: _record,
                version: 7,
                canWrite: true,
                cells: [
                  PlatformColumnCell(
                    columnId: _noteId,
                    definition: _note,
                    value: '编辑前原值',
                  ),
                ],
              ),
            )
            ..setValue(_note, '未提交原文');
          addTearDown(controller.dispose);
          addTearDown(draft.dispose);
          final before = draft.exportDraft()..remove('canWrite');
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                platformTableRepositoryProvider.overrideWithValue(
                  PlatformTableRepository(ApiClient(dio)),
                ),
                platformTableLayoutProvider(_table).overrideWith(
                  () => _Layout(
                    PlatformTableLayout(
                      added: [if (includeValid) _note, unavailable],
                      order: ['base', _malformed.key],
                      hidden: {_malformed.key},
                      pinned: {_malformed.key},
                      widths: {_malformed.key: 180},
                      sortColumn: _malformed.key,
                    ),
                  ),
                ),
              ],
              child: MaterialApp(
                home: Builder(
                  builder: (context) {
                    controller.configure(
                      context,
                      descriptor: const PlatformTableDescriptor<String>(
                        kind: 'editable',
                        rows: [_record],
                        columnKeys: ['base'],
                        tableKey: _table,
                      ),
                      explicitBinding: PlatformTableBinding<String>(
                        tableKey: _table,
                        scope: 'goods',
                        recordIdOf: (id) => id,
                        draftOf: (_) => draft,
                      ),
                    );
                    return const SizedBox();
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(controller.error, isNull);
          expect(controller.layout.added, [
            if (includeValid) _note,
            if (permissionHidden) unavailable,
          ]);
          expect(controller.layout.order, [
            'base',
            if (permissionHidden) _malformed.key,
          ]);
          expect(controller.layout.hidden, {
            if (permissionHidden) _malformed.key,
          });
          expect(controller.layout.pinned, {
            if (permissionHidden) _malformed.key,
          });
          expect(controller.layout.widths, {
            if (permissionHidden) _malformed.key: 180.0,
          });
          expect(
            controller.layout.sortColumn,
            permissionHidden ? _malformed.key : isNull,
          );
          // A complete authorized read may refresh write capability, while the
          // staged input, version and source identity must remain untouched.
          expect(draft.exportDraft()..remove('canWrite'), before);
          expect(
            requests.where((r) => r.path.endsWith('/definitions')),
            hasLength(includeValid ? 1 : 0),
          );
          expect(requests.where((r) => r.method != 'GET').map((r) => r.path), [
            '/platform-columns/goods/values:batch',
          ]);
        },
      );
    }
  }
}
