import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/pages/production_plan_detail_page.dart';

void main() {
  group('ProductionMrpErrorGuidance', () {
    test('classifies a missing BOM response', () {
      final guidance = ProductionMrpErrorGuidance.fromServerMessage(
        '至少一个生产计划行没有有效 BOM，无法生成物料需求',
      );

      expect(guidance.title, '计划产品缺少有效 BOM');
      expect(guidance.nextStep, contains('所有计划行'));
    });

    test('classifies a multi-level BOM response', () {
      final guidance = ProductionMrpErrorGuidance.fromServerMessage(
        '检测到多层 BOM，请先处理下层 BOM',
      );

      expect(guidance.title, 'BOM 层级当前无法处理');
      expect(guidance.nextStep, contains('独立生产计划'));
    });

    test('classifies combined color and unit validation', () {
      final guidance = ProductionMrpErrorGuidance.fromServerMessage(
        'BOM 颜色不存在，单位换算率无效',
      );

      expect(guidance.title, 'BOM 颜色或单位资料不完整');
      expect(guidance.nextStep, contains('基本单位和换算率'));
    });

    test('explains unit validation scope and BOM unit semantics', () {
      final guidance = ProductionMrpErrorGuidance.fromServerMessage(
        '货品 V51115 存在未完成采购行的单位或换算率无效，禁止计算齐套',
      );

      expect(guidance.title, '物料单位或换算率无效');
      expect(guidance.nextStep, contains('不另设 BOM 单位'));
      expect(guidance.nextStep, contains('仍有未收数量'));
      expect(guidance.nextStep, contains('没有未完成采购行'));
    });

    test('keeps a useful fallback for unknown server errors', () {
      final guidance = ProductionMrpErrorGuidance.fromServerMessage(
        'unexpected validation failure',
      );

      expect(guidance.title, '物料需求接口校验失败');
      expect(guidance.nextStep, contains('服务端原始提示'));
    });
  });

  testWidgets('shows guidance, raw error and an enabled retry action', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: ProductionMrpErrorPanel(
              serverMessage: '产品 280149012 没有有效 BOM',
              onRetry: () => retries++,
            ),
          ),
        ),
      ),
    );

    expect(find.text('计划产品缺少有效 BOM'), findsOneWidget);
    expect(find.textContaining('下一步：'), findsOneWidget);
    expect(find.text('服务端原始提示'), findsOneWidget);
    expect(find.text('产品 280149012 没有有效 BOM'), findsOneWidget);
    expect(find.text('重试加载'), findsOneWidget);

    await tester.tap(find.text('重试加载'));
    expect(retries, 1);
  });

  testWidgets('disables retry while a retry is already running', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProductionMrpErrorPanel(
            serverMessage: '单位换算率无效',
            isRetrying: true,
            onRetry: () => retries++,
          ),
        ),
      ),
    );

    expect(find.text('正在重试'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('正在重试'));
    expect(retries, 0);
  });
}
