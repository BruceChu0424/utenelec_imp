// 临时诊断（用完即删）：逐帧打印「添加组件」浮窗缩起/展开动画期间卡片矩形的
// 实际数值，验证用户反馈的「先变长触底、再收起/展开」。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

class _DiagRepo implements GoodsBomRepository {
  @override
  Future<List<GoodsBomItem>> list(String goodsId) async => const [];
  @override
  Future<BomPasteResult> paste({
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<Map<String, dynamic>> items,
  }) async => throw UnimplementedError();
  @override
  Future<int> deleteMany(String goodsId, List<String> itemIds) async =>
      throw UnimplementedError();
  @override
  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  ) async => throw UnimplementedError();
  @override
  Future<GoodsBomItem> setAudited(
    String goodsId,
    String itemId,
    bool audited,
  ) async => throw UnimplementedError();
  @override
  Future<GoodsBomLearningSummary> learning(String goodsId) async =>
      throw UnimplementedError();
  @override
  Future<GoodsBomLearningSummary> relearn(
    String goodsId,
    String componentGoodsId,
  ) async => throw UnimplementedError();
}

void _printCardRect(WidgetTester tester, String label) {
  // 两个几何分别量：外壳 DecoratedBox（稳态可见卡片）与 morph IgnorePointer（动画帧）。
  final root = tester.element(find.byType(UtenFloatingWindow));
  final boxes = <RenderBox>[];
  void walk(Element e) {
    if (e.widget is IgnorePointer) {
      final ro = e.findRenderObject();
      if (ro is RenderBox && ro.attached) boxes.add(ro);
    }
    e.visitChildren(walk);
  }

  walk(root);
  RenderBox? shell;
  try {
    final titleEl = tester.element(
      find
          .descendant(
            of: find.byType(UtenFloatingWindow),
            matching: find.text('添加组件'),
          )
          .first,
    );
    titleEl.visitAncestorElements((a) {
      if (a.widget is DecoratedBox) {
        final ro = a.findRenderObject();
        if (ro is RenderBox && ro.attached) shell = ro;
        return false;
      }
      return true;
    });
  } catch (_) {}
  void report(String name, RenderBox? box) {
    if (box == null) {
      // ignore: avoid_print
      print('$label [$name]: (none)');
      return;
    }
    final size = box.size;
    final topLeft = box.localToGlobal(Offset.zero);
    // ignore: avoid_print
    print(
      '$label [$name]: (${topLeft.dx.toStringAsFixed(1)}, ${topLeft.dy.toStringAsFixed(1)}, '
      '${size.width.toStringAsFixed(1)} x ${size.height.toStringAsFixed(1)}) '
      'bottom=${(topLeft.dy + size.height).toStringAsFixed(1)}',
    );
  }

  report('shell', shell);
  report('morph', boxes.isEmpty ? null : boxes.first);
}

Future<void> _open(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sensitiveReadBoundaryProvider.overrideWithValue(
          SensitiveReadBoundary(
            identity: null,
            api: ApiClient(Dio()),
            permissions: {Perm.goodsView, Perm.goodsBomCreate},
            superAdmin: false,
          ),
        ),
        goodsBomRepositoryProvider.overrideWithValue(_DiagRepo()),
        bomComponentPickerProvider.overrideWithValue(
          (context, ref) async => const [],
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          Perm.goodsBomCreate,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: Scaffold(
          body: GoodsBomTab(
            goodsId: 'goods-a',
            canCreate: true,
            canEdit: false,
            canDelete: false,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('goods-bom-add-component')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('缩起动画逐帧矩形', (tester) async {
    await _open(tester);
    _printCardRect(tester, 'before-click');

    await tester.tap(find.byTooltip('缩小成悬浮球'));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      _printCardRect(tester, 'collapse f$i');
    }
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.post_add_rounded));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      _printCardRect(tester, 'expand f$i');
    }
    await tester.pumpAndSettle();
    _printCardRect(tester, 'after-expand');
  });
}
