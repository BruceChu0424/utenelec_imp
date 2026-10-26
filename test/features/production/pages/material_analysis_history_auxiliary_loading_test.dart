import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_history_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final page = Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) => page.future;
}

class _Names extends MasterNameService {
  _Names() : super(ApiClient(Dio()));
  final ready = Completer<void>();

  @override
  Future<void> ensureCommonLoaded() => ready.future;
}

void main() {
  testWidgets('分析历史表壳先显示，列表完成不等待名称字典', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _Api();
    final names = _Names();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          masterNameServiceProvider.overrideWith((ref) => names),
          productionPlanRepositoryProvider.overrideWithValue(
            ProductionPlanRepository(api),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProductionMaterialAnalysisHistoryPage(),
        ),
      ),
    );
    await tester.pump();
    final finder = find.byType(MasterDataTableView<MaterialAnalysisListItem>);
    expect(finder, findsOneWidget);
    expect(
      tester
          .widget<MasterDataTableView<MaterialAnalysisListItem>>(finder)
          .isLoading,
      isTrue,
    );
    api.page.complete({
      'items': <Object?>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
    });
    await tester.pumpAndSettle();
    expect(names.ready.isCompleted, isFalse);
    expect(
      tester
          .widget<MasterDataTableView<MaterialAnalysisListItem>>(finder)
          .isLoading,
      isFalse,
    );
    expect(find.text('没有符合条件的物料分析记录'), findsOneWidget);
    names.ready.completeError(StateError('dictionary unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的物料分析记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
