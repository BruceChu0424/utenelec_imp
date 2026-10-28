// Synthetic UI acceptance entry point. It never contacts a business server.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/goods_import.dart';
import 'package:uten_imp/features/basic_data/pages/goods_import_preview_page.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_import_mode_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

void main() => runApp(
  ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(_PreviewApi()),
      apiBaseUrlProvider.overrideWithValue('http://127.0.0.1:53528/synthetic'),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'preview-only'),
      ),
      currentPermissionsProvider.overrideWithValue({
        'goods:view',
        'goods:export',
      }),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const _Harness(),
    ),
  ),
);

class _PreviewApi extends ApiClient {
  _PreviewApi() : super(Dio());
  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    throw ApiException('VALIDATION', '模拟等待已结束，未生成业务文件');
  }
}

class _Harness extends ConsumerWidget {
  const _Harness();

  GoodsImportReport _report(
    bool problems,
    GoodsImportCorrections corrections,
    Set<int> excluded,
  ) {
    final rows = <GoodsImportProblemRow>[
      for (var i = 2; i <= 9; i++)
        GoodsImportProblemRow(
          rowNum: i,
          code: '280134${i.toString().padLeft(3, '0')}',
          name: i == 4 && problems ? '' : '${i.isEven ? '单联' : '双联'}开关功能件 $i',
          categoryPath: i <= 6
              ? '货品资料 / 成品 / V3系列 / 白色'
              : '货品资料 / 成品 / V3系列 / 黑色',
          cells: {
            'model': 'PGK${i.isEven ? "1" : "2"}.1',
            'unitName': '只',
            'sourceType': '自产',
            'colorName': i <= 6 ? '白色' : '黑色',
          },
        ),
    ];
    final bad =
        problems &&
        (corrections[4]?['name'] ?? '').isEmpty &&
        !excluded.contains(4);
    return GoodsImportReport(
      totalRows: 9,
      dataRows: 8,
      errors: [
        if (bad)
          const GoodsImportError(rowNum: 4, column: '货品名称', message: '请填写货品名称'),
      ],
      willCreateCategories: const [],
      willCreateColors: const [],
      willCreateUnits: const [],
      readyToImport: 8 - excluded.length - (bad ? 1 : 0),
      restorableRows: 0,
      planId: 'synthetic-preview',
      readyRowNums: [
        for (final row in rows)
          if (!excluded.contains(row.rowNum) && !(bad && row.rowNum == 4))
            row.rowNum,
      ],
      previewRows: [
        for (final row in rows)
          if (!excluded.contains(row.rowNum))
            GoodsImportProblemRow(
              rowNum: row.rowNum,
              code: corrections[row.rowNum]?['code'] ?? row.code,
              name: corrections[row.rowNum]?['name'] ?? row.name,
              categoryPath:
                  corrections[row.rowNum]?['categoryPath'] ?? row.categoryPath,
              cells: {...row.cells, ...?corrections[row.rowNum]},
            ),
      ],
    );
  }

  Future<void> _preview(BuildContext context, bool problems) async {
    final decision = await Navigator.of(context)
        .push<GoodsImportPreviewDecision>(
          MaterialPageRoute(
            builder: (_) => GoodsImportPreviewPage(
              report: _report(problems, const {}, const {}),
              filename: 'V3系列货品.xlsx',
              mode: problems
                  ? GoodsImportMode.mixed
                  : GoodsImportMode.createOnly,
              onDraftChanged: (_, _) {},
              detect: (corrections, excluded) async {
                await Future<void>.delayed(const Duration(milliseconds: 800));
                return _report(problems, corrections, excluded);
              },
            ),
          ),
        );
    if (decision != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已确认 ${decision.report.readyRowNums.length} 条（模拟数据，未写入）',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('基础资料交互验收（模拟数据）')),
    body: Center(
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          UtenButton(
            onPressed: () => _preview(context, false),
            child: const Text('正常新建预览'),
          ),
          UtenButton(
            onPressed: () => _preview(context, true),
            child: const Text('问题修正预览'),
          ),
          UtenButton(
            onPressed: () => showGoodsImportWithModePicker(context, ref),
            child: const Text('导入方式弹窗'),
          ),
          const UtenExportButton(
            endpoint: '/synthetic',
            report: 'goods',
            queryParams: {},
            filename: '货品资料',
            label: '导出货品',
          ),
        ],
      ),
    ),
  );
}
