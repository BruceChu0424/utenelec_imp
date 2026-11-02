import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_empty.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/action_feedback.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/ui/human_error_message.dart';
import 'package:uten_imp/core/ui/uten_notify.dart';

void main() {
  final contract =
      jsonDecode(
            File('contracts/user-error-message/v1.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final item in contract['cases'] as List<dynamic>) {
    final value = item as Map<String, dynamic>;
    test('shared error copy: ${value['code']} / ${value['message']}', () {
      final error = ApiException(
        value['code'] as String,
        value['message'] as String,
        httpStatus: value['status'] as int?,
      );
      expect(humanErrorMessage(error), value['expected']);
      expect(error.code, value['code']);
      expect(error.httpStatus, value['status']);
    });
  }
  test('framework response copy does not invent a server response code', () {
    final error = ApiExceptionFactory.fromDioStatusCode(
      503,
      ApiError.fromJson({'message': 'Service Unavailable'}),
    );
    expect(error.hasResponseCode, isFalse);
    expect(error.code, 'UNKNOWN');
    expect(error.httpStatus, 503);
    expect(error.message, '服务器处理异常，请先刷新核对操作结果');
  });
  test('specific field validation and wire evidence stay intact', () {
    const fields = [ApiFieldError(field: 'warehouseId', message: '请选择收货仓库')];
    final error = ApiException.fromApiError(
      const ApiError(
        code: 'VALIDATION_FAILED',
        message: '请选择收货仓库后再登记',
        fieldErrors: fields,
      ),
      httpStatus: 422,
    );
    expect(error.message, '请选择收货仓库后再登记');
    expect(error.fieldErrors, same(fields));
    expect(error.hasResponseCode, isTrue);
  });
  test('local protection reasons survive all-catch notification paths', () {
    expect(humanErrorMessage(StateError('草稿尚未保存，请保留原输入')), '草稿尚未保存，请保留原输入');
    expect(
      humanErrorMessage(TimeoutException('timer expired')),
      '操作等待超时，请先核对结果再继续',
    );
    expect(humanErrorMessage(StateError('No element')), isNull);
  });

  for (final surface in ['top', 'center', 'page', 'guard', 'validation']) {
    testWidgets('specific cause is visible in the $surface error surface', (
      tester,
    ) async {
      final error = surface == 'validation'
          ? ApiException(
              'VALIDATION_FAILED',
              '填写内容有误',
              httpStatus: 422,
              fieldErrors: const [
                ApiFieldError(field: 'warehouseId', message: '请选择收货仓库'),
              ],
            )
          : ApiException('FORBIDDEN', 'Access Denied', httpStatus: 403);
      final expected = switch (surface) {
        'guard' => '草稿尚未保存，请保留原输入',
        'validation' => '请检查：请选择收货仓库',
        _ => error.message,
      };
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Stack(
                children: [
                  Builder(
                    builder: (context) => surface == 'page'
                        ? UtenEmpty.error(error: error)
                        : Center(
                            child: TextButton(
                              onPressed: () {
                                switch (surface) {
                                  case 'top':
                                  case 'validation':
                                    UtenNotify.apiError(context, error);
                                  case 'center':
                                    unawaited(
                                      UtenNotify.alert(
                                        context,
                                        title: '操作无法继续',
                                        message: humanErrorMessage(error),
                                      ),
                                    );
                                  case 'guard':
                                    unawaited(
                                      context.guardRun(
                                        () async => throw StateError(expected),
                                      ),
                                    );
                                }
                              },
                              child: const Text('触发'),
                            ),
                          ),
                  ),
                  const AppNotificationHost(),
                ],
              ),
            ),
          ),
        ),
      );
      if (surface != 'page') await tester.tap(find.text('触发'));
      await tester.pumpAndSettle();
      expect(find.text(expected), findsOneWidget);
      expect(find.text('Access Denied'), findsNothing);
      if (surface == 'validation') {
        expect(find.textContaining('warehouseId'), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
