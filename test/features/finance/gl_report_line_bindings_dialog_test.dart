import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/widgets/gl_report_line_bindings_dialog.dart';

/// ADR-112 / overhaul-gap-03: 附表取数设置——未配置的行明确标注, 选费用末级科目后整行保存,
/// 「按默认名单补齐」调用服务端同一个库函数。
void main() {
  testWidgets(
    'lists unconfigured rows, saves the picked leaf and seeds defaults',
    (tester) async {
      final api = _Api();
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      bool? changed;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(api)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    changed = await showGlReportLineBindingsDialog(
                      context,
                      canEdit: true,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('未配置科目'), findsOneWidget);
      expect(find.text('未配置部门'), findsOneWidget);
      expect(find.text('房租 (6601)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('gl-line-edit-ADM_OFFICE')));
      await tester.pumpAndSettle();
      expect(api.lastQuery, {'category': 'EXPENSE'});
      // 只列末级科目; 目录「管理费用」不出现, 停用的末级标注后可选。
      expect(find.textContaining('管理费用 / 办公费用 (6602)'), findsOneWidget);
      expect(find.textContaining('旧办公费 (6603) (停用)'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('gl-line-target-style-office')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('gl-line-target-save')));
      await tester.pumpAndSettle();
      expect(api.putPath, '/finance/reports/gl/line-bindings/ADM_OFFICE');
      expect(api.putBody, {
        'targetIds': ['style-office'],
      });
      expect(find.text('办公费用 (6602)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('gl-line-seed-defaults')));
      await tester.pumpAndSettle();
      expect(api.postPath, '/finance/reports/gl/line-bindings/defaults');

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(changed, isTrue);
    },
  );

  test('department tree flattens every level with indentation depth', () {
    final flat = flattenDepartments([
      {
        'id': 'd1',
        'code': 'D1',
        'name': '生产部',
        'children': [
          {'id': 'd2', 'code': 'D2', 'name': '注塑车间', 'children': <Object>[]},
        ],
      },
    ]);
    expect(flat.map((item) => item.label), ['生产部 (D1)', '注塑车间 (D2)']);
    expect(flat.map((item) => item.depth), [0, 1]);
  });
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  List<Map<String, dynamic>> lines = [
    {
      'lineKey': 'ADM_RENT',
      'label': '厂房及成品仓租赁费',
      'bindingKind': 'STYLE',
      'targets': [
        {'id': 'style-rent', 'code': '6601', 'name': '房租'},
      ],
    },
    {
      'lineKey': 'ADM_OFFICE',
      'label': '办公费',
      'bindingKind': 'STYLE',
      'targets': <Object>[],
    },
    {
      'lineKey': 'LABOR_DIRECT',
      'label': '直接人工',
      'bindingKind': 'DEPARTMENT',
      'targets': <Object>[],
    },
  ];
  Map<String, dynamic>? lastQuery;
  String? putPath;
  Object? putBody;
  String? postPath;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/reports/gl/line-bindings') return lines;
    lastQuery = query;
    return [
      {
        'id': 'style-admin',
        'code': '66',
        'name': '管理费用',
        'category': 'EXPENSE',
        'status': '使用',
        'children': [
          {
            'id': 'style-office',
            'code': '6602',
            'name': '办公费用',
            'category': 'EXPENSE',
            'status': '使用',
            'children': <Object>[],
          },
          {
            'id': 'style-old',
            'code': '6603',
            'name': '旧办公费',
            'category': 'EXPENSE',
            'status': '禁用',
            'children': <Object>[],
          },
        ],
      },
    ];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    putPath = path;
    putBody = body;
    return {
      'lineKey': 'ADM_OFFICE',
      'label': '办公费',
      'bindingKind': 'STYLE',
      'targets': [
        {'id': 'style-office', 'code': '6602', 'name': '办公费用'},
      ],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async {
    postPath = path;
    return lines;
  }
}
