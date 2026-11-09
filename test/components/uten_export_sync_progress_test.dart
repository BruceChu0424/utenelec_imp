import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

/// 服务端整份生成后才发送字节: 同步导出的进度必须来自服务端登记的生成进度,
/// 按「已读 / 总数」一步一步前进, 不能 0 直接跳 100(2026-11-08 用户验收反馈)。
class _GeneratingApi extends ApiClient {
  _GeneratingApi() : super(Dio());

  final file = Completer<Uint8List>();

  /// 服务端此刻登记的生成进度; null = 尚未登记或已结束(204, ApiClient 读成空对象)。
  Map<String, dynamic>? current;
  Map<String, String>? headers;
  final polled = <String>[];

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
    Map<String, String>? headers,
  }) {
    this.headers = headers;
    return file.future;
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.startsWith('/exports/progress/')) polled.add(path);
    return current ?? <String, dynamic>{};
  }
}

Future<void> _openExport(WidgetTester tester, _GeneratingApi api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'a'),
        ),
        apiBaseUrlProvider.overrideWithValue('https://a.invalid'),
        currentPermissionsProvider.overrideWithValue({}),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: UtenExportButton(
            endpoint: '/export',
            report: 'goods',
            queryParams: {},
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.bySemanticsLabel('下载表格'));
  await tester.pumpAndSettle();
  if (find.byKey(const ValueKey('table-output-all')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('table-output-all')));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('直接下载'));
  await tester.pump();
  await tester.pump();
}

String? _percent(WidgetTester tester) {
  final figure = find.byKey(const ValueKey('uten-progress-percent'));
  return figure.evaluate().isEmpty ? null : tester.widget<Text>(figure).data;
}

Future<void> _poll(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
  // 数字在 500ms 内平滑跳到新值。
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('a synchronous export climbs step by step with the server\'s '
      'generation progress, then completes', (tester) async {
    final api = _GeneratingApi()
      ..current = {'rows': 0, 'total': 39000, 'phase': 'READING'};
    await _openExport(tester, api);

    // 带上操作号, 服务端据此登记可轮询的生成进度。
    final operation = api.headers?['X-Uten-Export-Operation'];
    expect(operation, matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(find.text('正在读取数据'), findsOneWidget);

    await _poll(tester);
    expect(api.polled.toSet(), {'/exports/progress/$operation'});
    expect(_percent(tester), '0');
    expect(find.text('0 / 39,000 行'), findsOneWidget);

    api.current = {'rows': 13000, 'total': 39000, 'phase': 'READING'};
    await _poll(tester);
    expect(_percent(tester), '30');
    expect(find.text('13,000 / 39,000 行'), findsOneWidget);

    api.current = {'rows': 26000, 'total': 39000, 'phase': 'READING'};
    await _poll(tester);
    expect(_percent(tester), '60');

    api.current = {'rows': 39000, 'total': 39000, 'phase': 'PACKAGING'};
    await _poll(tester);
    expect(_percent(tester), '92');
    expect(find.text('正在生成文件'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 文件保存走真实磁盘 I/O, 已由导出按钮既有用例覆盖; 这里以服务端拒绝收尾,
    // 核对弹窗关闭、轮询停止且没有残留定时器。
    api.file.completeError(StateError('generation rejected'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uten-progress-percent')), findsNothing);
    final polls = api.polled.length;
    await tester.pump(const Duration(seconds: 2));
    expect(api.polled.length, polls, reason: '导出结束后不再轮询');
  });

  testWidgets('an unknown total keeps the sweep bar with the rows read so far, '
      'never a fake percentage', (tester) async {
    final api = _GeneratingApi()
      ..current = {'rows': 4200, 'total': null, 'phase': 'READING'};
    await _openExport(tester, api);

    await _poll(tester);
    expect(_percent(tester), isNull);
    expect(find.text('已读取 4,200 行'), findsOneWidget);

    api.file.completeError(StateError('generation rejected'));
    await tester.pumpAndSettle();
  });

  testWidgets('a poll answered "no progress" (204) before registration or '
      'after the end never resets what is shown', (tester) async {
    final api = _GeneratingApi();
    await _openExport(tester, api);

    await _poll(tester);
    expect(api.polled, isNotEmpty);
    expect(_percent(tester), isNull, reason: '尚未登记时不伪造 0%');
    expect(find.text('正在读取数据'), findsOneWidget);
    expect(find.textContaining('已读取'), findsNothing);

    api.current = {'rows': 13000, 'total': 39000, 'phase': 'READING'};
    await _poll(tester);
    expect(_percent(tester), '30');

    api.current = null;
    await _poll(tester);
    expect(_percent(tester), '30', reason: '空回答保持当前进度, 不回退');
    expect(find.text('13,000 / 39,000 行'), findsOneWidget);

    api.file.completeError(StateError('generation rejected'));
    await tester.pumpAndSettle();
  });

  testWidgets('cancel stops waiting at once and stops polling', (tester) async {
    final api = _GeneratingApi()
      ..current = {'rows': 100, 'total': 39000, 'phase': 'READING'};
    await _openExport(tester, api);
    await _poll(tester);

    await tester.tap(find.byKey(const ValueKey('uten-progress-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uten-progress-cancel')), findsNothing);

    final polls = api.polled.length;
    await tester.pump(const Duration(seconds: 2));
    expect(api.polled.length, polls, reason: '取消后不再轮询');
    api.file.complete(Uint8List.fromList([1]));
    await tester.pumpAndSettle();
  });
}
