// Local, synthetic interaction fixture. Never contacts a business server.
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _LocalApi extends ApiClient {
  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
    Map<String, String>? headers,
  }) async => throw const FormatException('本地合成数据只用于交互验证，不生成正式文件');

  _LocalApi() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {'available': false, 'selectionVersion': 1};
}

void main() => runApp(
  ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(_LocalApi()),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'local-output-fixture'),
      ),
      apiBaseUrlProvider.overrideWithValue('https://fixture.invalid'),
      currentPermissionsProvider.overrideWithValue(const {}),
    ],
    child: const _Harness(),
  ),
);

class _Harness extends StatefulWidget {
  const _Harness();
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final projection = TableColumnProjectionController();
  final rows = List.generate(
    3000,
    (i) => {
      'id': 'fixture-$i',
      'code': 'MJ-${i.toString().padLeft(4, '0')}',
      'name': '本地测试模具 $i',
    },
  );
  @override
  void dispose() {
    projection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildLightTheme(),
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: TableColumnProjectionScope(
      controller: projection,
      child: Scaffold(
        appBar: AppBar(title: const Text('表格输出本地交互验证')),
        body: MasterDataTableView<Map<String, String>>(
          tableKey: 'local.output.scope',
          virtualized: true,
          expensiveRowMounts: false,
          columns: [
            MasterColumnDef(
              key: 'code',
              label: '模具编号',
              width: 180,
              value: (row) => row['code'],
            ),
            MasterColumnDef(
              key: 'name',
              label: '模具名称',
              width: 320,
              value: (row) => row['name'],
            ),
          ],
          items: rows,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          toolbarActions: const [
            UtenExportButton(
              endpoint: '/fixture/export',
              report: '',
              queryParams: {},
              filename: '模具盘点清单',
              label: '导出模具',
            ),
          ],
        ),
      ),
    ),
  );
}
