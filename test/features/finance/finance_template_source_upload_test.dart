import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/finance/shared/finance_template_source_upload.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

void main() {
  testWidgets(
    'explicit sheet choice reuses the exact workbook and original period without picking a default',
    (tester) async {
      final api = _Api();
      final state = await _mount(tester, api);
      await tester.tap(find.text('导入测试原表'));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(1));
      expect(
        tester.widget<UtenDropdownField>(find.byType(UtenDropdownField)).value,
        isNull,
      );
      await tester.tap(find.byType(UtenDropdownField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('原附件乙').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入所选工作表'));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(2));
      expect(api.queries.first, isNot(contains('sourceSheet')));
      expect(api.queries.last, containsPair('sourceSheet', '原附件乙'));
      expect(api.queries.last, containsPair('period', '2026-09'));
      expect(api.queries.last, containsPair('filename', '财务多附件原表.xlsx'));
      expect(api.bytes.last, orderedEquals(api.bytes.first));
      expect(state.result?['sourceSheet'], '原附件乙');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.container.dispose();
    },
  );
  testWidgets(
    'cancelled sheet choice leaves the old source untouched and sends no selected upload',
    (tester) async {
      final api = _Api();
      final state = await _mount(tester, api);
      await tester.tap(find.text('导入测试原表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(state.result, isNull);
      expect(api.queries, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.container.dispose();
    },
  );
  testWidgets(
    'source chooser retires on scope change and does not revive after ABA',
    (tester) async {
      final api = _Api();
      final state = await _mount(tester, api);
      await tester.tap(find.text('导入测试原表'));
      await tester.pumpAndSettle();
      final epoch =
          state.container.read(exportContextEpochProvider.notifier) as _Epoch;
      epoch.setValue(1);
      await tester.pumpAndSettle();
      expect(find.byType(UtenDropdownField), findsNothing);
      epoch.setValue(0);
      await tester.pumpAndSettle();
      expect(find.byType(UtenDropdownField), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(1));
      expect(state.result, isNull);
      await tester.pumpWidget(const SizedBox());
      state.container.dispose();
    },
  );
  testWidgets(
    'unknown transport failure never opens sheet selection or automatically retries bytes',
    (tester) async {
      final api = _Api()..unknown = true;
      final state = await _mount(tester, api);
      await tester.tap(find.text('导入测试原表'));
      await tester.pumpAndSettle();
      expect(state.error, isA<NetworkTimeoutException>());
      expect(api.queries, hasLength(1));
      expect(find.byType(UtenDropdownField), findsNothing);
      await tester.pumpWidget(const SizedBox());
      state.container.dispose();
    },
  );
}

class _State {
  _State(this.container);
  final ProviderContainer container;
  Map<String, dynamic>? result;
  Object? error;
}

Future<_State> _mount(WidgetTester tester, _Api api) async {
  await tester.binding.setSurfaceSize(const Size(430, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      exportContextEpochProvider.overrideWith(_Epoch.new),
    ],
  );
  final state = _State(container);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => UtenButton(
              onPressed: () async {
                try {
                  state.result = await uploadFinanceTemplateSource(
                    context: context,
                    api: api,
                    bytes: Uint8List.fromList([0, 255, 1, 8]),
                    query: {
                      'template': 'copperDetail',
                      'period': '2026-09',
                      'filename': '财务多附件原表.xlsx',
                    },
                    asset: false,
                    isCurrent: () =>
                        container.read(exportContextEpochProvider) == 0,
                  );
                } catch (error) {
                  state.error = error;
                }
              },
              child: const Text('导入测试原表'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

class _Epoch extends ExportContextEpoch {
  @override
  int build() => 0;
  void setValue(int value) {
    state = value;
  }
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  bool unknown = false;
  final queries = <Map<String, dynamic>>[];
  final bytes = <Uint8List>[];
  @override
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List body, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    Duration? sendTimeout,
    Duration? receiveTimeout,
  }) async {
    queries.add(Map<String, dynamic>.from(query ?? {}));
    bytes.add(Uint8List.fromList(body));
    if (unknown) throw NetworkTimeoutException();
    if (query?['sourceSheet'] == null) {
      throw ApiException(
        'VALIDATION_FAILED',
        '请按原名选择工作表',
        httpStatus: 400,
        hasResponseCode: true,
        fieldErrors: [
          for (final value in ['原附件甲', '原附件乙'])
            ApiFieldError(field: 'sourceSheet', message: value),
        ],
      );
    }
    return {
      'importId': '10000000-0000-0000-0000-000000000001',
      'sourceSheet': query!['sourceSheet'],
    };
  }
}
