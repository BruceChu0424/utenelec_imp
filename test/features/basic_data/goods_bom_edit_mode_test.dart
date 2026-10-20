import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/providers/goods_clipboard.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import '../../support/audit_screenshot_support.dart';

final _permissions = NotifierProvider<_Permissions, Set<String>>(
  _Permissions.new,
);

class _Permissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => {
    Perm.goodsView,
    Perm.goodsBomEdit,
    Perm.goodsBomCreate,
    Perm.goodsBomDelete,
    Perm.goodsBomAudit,
  };

  void replace(Set<String> value) => state = value;
}

Map<String, dynamic> _row(String id, String component, String name) => {
  'id': id,
  'componentGoodsId': component,
  'componentName': name,
  'componentCode': 'C-$component',
  'componentUnitName': '个',
  'qty': 2,
  'controlStage': 'FINISH',
  'consumptionBasis': 'PER_PACKAGE',
  'basisOutputQty': 10,
  'allowPartialPackage': false,
  'hardGate': true,
  'systemLearned': true,
  'actualQty': 3,
  'actualSampleCount': 8,
  'auditedAt': '2026-01-01T00:00:00Z',
};

class _Api extends ApiClient {
  _Api() : super(Dio());

  final commands = <(String, Map<String, dynamic>)>[];
  List<String> previewWarnings = const [];
  Completer<GoodsBomItem>? pendingAudit;
  final tree = <String, List<Map<String, dynamic>>>{
    'source': [
      _row('row-frame', 'frame', '铁架'),
      _row('row-screw', 'screw', '螺丝'),
    ],
    'target': [_row('row-nut', 'nut', '螺母')],
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/snapshot')) {
      final goodsId = path.split('/').reversed.elementAt(3);
      return {'items': tree[goodsId] ?? [], 'fingerprint': 'fp-$goodsId'};
    }
    final id = path.split('/').last;
    return {
      'id': id,
      'name': switch (id) {
        'frame' => '铁架',
        'screw' => '螺丝',
        _ => id,
      },
      'unitName': '个',
      'issueMethod': 'ORDER',
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    final request = Map<String, dynamic>.from(body! as Map);
    commands.add((path, request));
    if (path.endsWith('/preview')) {
      return {
        'previewToken': 'review',
        'operationCount': (request['operations'] as List).length,
        'affectedParents': [
          {'goodsId': 'frame', 'goodsName': '铁架', 'otherUsageCount': 3},
        ],
        'otherUsageCount': 3,
        'warnings': previewWarnings,
      };
    }
    return {};
  }
}

class _Repository extends Fake implements GoodsBomRepository {
  _Repository(this.api);
  final _Api api;

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async => [
    for (final row in api.tree[goodsId] ?? const <Map<String, dynamic>>[])
      GoodsBomItem.fromJson(row),
  ];

  @override
  Future<GoodsBomLearningSummary> learning(String goodsId) async =>
      const GoodsBomLearningSummary();

  @override
  Future<GoodsBomItem> setAudited(
    String goodsId,
    String itemId,
    bool audited,
  ) async {
    if (api.pendingAudit case final pending?) return pending.future;
    return GoodsBomItem.fromJson(
      api.tree[goodsId]!.firstWhere((row) => row['id'] == itemId),
    );
  }
}

class _Fixture {
  _Fixture(this.api, this.container, this.goodsId);
  final _Api api;
  final ProviderContainer container;
  final ValueNotifier<String> goodsId;
}

Future<_Fixture> _pump(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _Api();
  final container = ProviderContainer(
    overrides: [
      localServerReachableProvider.overrideWith(
        (ref) => LocalServerReachabilityNotifier(null, web: true),
      ),
      apiClientProvider.overrideWithValue(api),
      goodsBomRepositoryProvider.overrideWithValue(_Repository(api)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      isSuperAdminProvider.overrideWithValue(false),
      sensitiveReadBoundaryProvider.overrideWith(
        (ref) => SensitiveReadBoundary(
          identity: null,
          api: api,
          permissions: ref.watch(currentPermissionsProvider),
          superAdmin: false,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final goodsId = ValueNotifier('source');
  addTearDown(goodsId.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: brightness == Brightness.dark
            ? buildDarkTheme()
            : buildLightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: RepaintBoundary(
            key: const Key('bom-test-render'),
            child: child!,
          ),
        ),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: ValueListenableBuilder<String>(
                  valueListenable: goodsId,
                  builder: (_, id, _) => GoodsBomTab(
                    goodsId: id,
                    canCreate: true,
                    canEdit: true,
                    canDelete: true,
                  ),
                ),
              ),
              const Align(
                alignment: Alignment.topCenter,
                child: AppNotificationHost(),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Fixture(api, container, goodsId);
}

Future<void> _edit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
  await tester.pumpAndSettle();
}

Future<void> _menu(WidgetTester tester, String name) async {
  await tester.tap(
    find.text(name).first,
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('bom-test-render')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/task-visual-checks/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets(
    'default is read only and create/delete cannot grant entry without edit permission',
    (tester) async {
      final fixture = await _pump(tester);
      expect(find.text('编辑模式'), findsOneWidget);
      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
      expect(find.byKey(const Key('goods-bom-delete-selected')), findsNothing);
      await _menu(tester, '铁架');
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).at(1)).value,
        isTrue,
      );
      expect(find.text('添加子组件'), findsNothing);
      expect(find.text('粘贴'), findsNothing);
      fixture.container.read(_permissions.notifier).replace({
        Perm.goodsView,
        Perm.goodsBomCreate,
        Perm.goodsBomDelete,
      });
      await tester.pumpAndSettle();
      expect(find.text('编辑模式'), findsNothing);
      expect(fixture.api.commands, isEmpty);
    },
  );

  testWidgets(
    'delete is only staged and all shared changes wait for reviewed confirmation',
    (tester) async {
      final fixture = await _pump(tester);
      fixture.api.previewWarnings = ['单个重量与货品资料单重相差超过 20%，请核对'];
      await _edit(tester);
      expect(find.text('退出并保存'), findsOneWidget);
      await _menu(tester, '铁架');
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goods-bom-batch-delete-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('铁架'), findsNothing);
      expect(fixture.api.commands, isEmpty);
      expect(fixture.api.tree['source'], hasLength(2));
      await _edit(tester);
      expect(find.textContaining('其他 3 处'), findsOneWidget);
      expect(find.text('单个重量与货品资料单重相差超过 20%，请核对'), findsOneWidget);
      expect(fixture.api.commands.single.$1, endsWith('/preview'));
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('退出并保存'), findsOneWidget);
      expect(fixture.api.commands, hasLength(1));
      await _edit(tester);
      await tester.tap(find.byKey(const Key('goods-bom-save-confirm')));
      await tester.pumpAndSettle();
      expect(fixture.api.commands.last.$1, endsWith('/commit'));
      expect(fixture.api.commands.last.$2['confirmSharedChanges'], isTrue);
      expect(find.text('编辑模式'), findsOneWidget);
    },
  );

  testWidgets(
    'edit permission alone does not expose create, paste, import or delete actions',
    (tester) async {
      final fixture = await _pump(tester);
      fixture.container.read(_permissions.notifier).replace({
        Perm.goodsView,
        Perm.goodsBomEdit,
      });
      await tester.pumpAndSettle();
      await _edit(tester);
      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
      expect(find.byKey(const Key('goods-bom-import')), findsNothing);
      expect(find.byKey(const Key('goods-bom-delete-selected')), findsNothing);
      await _menu(tester, '铁架');
      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('添加子组件'), findsNothing);
      expect(find.text('删除'), findsNothing);
      expect(find.text('粘贴'), findsNothing);
    },
  );

  testWidgets(
    'permission changes release old audit waits and discard late responses',
    (tester) async {
      final fixture = await _pump(tester);
      final pending = fixture.api.pendingAudit = Completer<GoodsBomItem>();
      await tester.tap(find.byKey(const Key('goods-bom-audit-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('已核对，点击取消').first);
      await tester.pump();
      fixture.container.read(_permissions.notifier).replace({
        Perm.goodsView,
        Perm.goodsBomEdit,
      });
      await tester.pumpAndSettle();
      expect(find.text('铁架'), findsOneWidget);
      expect(find.text('退出审计'), findsNothing);
      pending.complete(
        const GoodsBomItem(
          id: 'row-frame',
          componentGoodsId: 'frame',
          componentName: '过时数据',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('过时数据'), findsNothing);
    },
  );

  testWidgets(
    'right click preserves a multi-selection and copies design values to another product child',
    (tester) async {
      final fixture = await _pump(tester);
      await _edit(tester);
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pumpAndSettle();
      await _menu(tester, '铁架');
      await tester.tap(find.text('复制').last);
      await tester.pumpAndSettle();
      expect(
        fixture.container.read(goodsClipboardProvider).bomItems,
        hasLength(2),
      );
      fixture.goodsId.value = 'target';
      await tester.pumpAndSettle();
      await _edit(tester);
      await _menu(tester, '螺母');
      await tester.tap(find.text('粘贴').last);
      await tester.pumpAndSettle();
      expect(find.text('铁架'), findsOneWidget);
      expect(find.text('螺丝'), findsOneWidget);
      expect(fixture.api.commands, isEmpty);
      await _edit(tester);
      final operations = fixture.api.commands.single.$2['operations'] as List;
      expect(operations, hasLength(2));
      for (final operation in operations) {
        final op = Map<String, dynamic>.from(operation as Map);
        expect(op['goodsId'], 'nut');
        final body = op['body'] as Map;
        expect(body['qty'], 2);
        expect(body['controlStage'], 'FINISH');
        expect(body['consumptionBasis'], 'PER_PACKAGE');
        expect(body.containsKey('actualQty'), isFalse);
        expect(body.containsKey('systemLearned'), isFalse);
        expect(body.containsKey('auditedAt'), isFalse);
      }
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'changing permissions invalidates an open dialog and clears clipboard without saving',
    (tester) async {
      final fixture = await _pump(tester);
      await _edit(tester);
      await _menu(tester, '铁架');
      await tester.tap(find.text('复制').last);
      await tester.pumpAndSettle();
      expect(
        fixture.container.read(goodsClipboardProvider).bomItems,
        isNotEmpty,
      );
      await _menu(tester, '铁架');
      await tester.tap(find.text('编辑').last);
      await tester.pumpAndSettle();
      final oldSave = tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '保存').last)
          .onPressed!;
      fixture.container.read(_permissions.notifier).replace({Perm.goodsView});
      await tester.pumpAndSettle();
      expect(find.text('编辑组件'), findsNothing);
      expect(find.text('保存'), findsNothing);
      oldSave();
      await tester.pumpAndSettle();
      expect(fixture.api.commands, isEmpty);
      expect(fixture.container.read(goodsClipboardProvider).bomItems, isNull);
      expect(find.text('退出并保存'), findsNothing);
    },
  );

  testWidgets(
    'copying an assembly and its descendant preserves the hierarchy once',
    (tester) async {
      final fixture = await _pump(tester);
      fixture.api.tree['source']!.first['hasChildren'] = true;
      fixture.api.tree['frame'] = [_row('row-washer', 'washer', '垫片')];
      await _edit(tester);
      await tester.tap(
        find.byKey(const ValueKey('goods-bom-tree-toggle-row-frame')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('铁架'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('垫片'));
      await tester.pumpAndSettle();
      await _menu(tester, '铁架');
      await tester.tap(find.text('复制').last);
      await tester.pumpAndSettle();
      expect(
        fixture.container
            .read(goodsClipboardProvider)
            .bomItems!
            .map((row) => row.componentGoodsId),
        ['frame'],
      );
    },
  );

  testWidgets('paste with no selection appends to the product top level', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    await _edit(tester);
    await _menu(tester, '铁架');
    await tester.tap(find.text('复制').last);
    await tester.pumpAndSettle();
    fixture.goodsId.value = 'target';
    await tester.pumpAndSettle();
    await _edit(tester);
    await tester.tapAt(
      const Offset(600, 400),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('粘贴').last);
    await tester.pumpAndSettle();
    expect(find.text('铁架'), findsOneWidget);
    await _edit(tester);
    final operations = fixture.api.commands.single.$2['operations'] as List;
    expect((operations.single as Map)['goodsId'], 'target');
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
  });

  testWidgets('fullscreen retains edit mode and permissions', (tester) async {
    await loadAuditScreenshotFonts(tester);
    await _pump(tester);
    await _edit(tester);
    await tester.tap(
      find.byKey(const ValueKey('master-table-fullscreen-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.text('退出全屏'), findsOneWidget);
    expect(find.text('退出并保存'), findsOneWidget);
    await _menu(tester, '铁架');
    expect(find.text('添加子组件'), findsOneWidget);
    await tester.tapAt(const Offset(1100, 700));
    await tester.pumpAndSettle();
    await _capture(tester, 'bom-edit-fullscreen-1440');
  });

  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    for (final brightness in Brightness.values) {
      testWidgets('mode controls fit at $size in $brightness with 2x text', (
        tester,
      ) async {
        await loadAuditScreenshotFonts(tester);
        await _pump(tester, size: size, brightness: brightness, textScale: 2);
        await _capture(
          tester,
          'bom-readonly-${size.width.toInt()}-${brightness.name}-2x',
        );
        await _edit(tester);
        expect(find.text('退出并保存'), findsOneWidget);
        expect(
          find.byKey(const Key('goods-bom-add-component')),
          findsOneWidget,
        );
        for (final key in [
          'goods-bom-add-component',
          'goods-bom-delete-selected',
          'goods-bom-edit-mode',
          'goods-bom-audit-mode',
        ]) {
          await tester.ensureVisible(find.byKey(Key(key)));
          await tester.pumpAndSettle();
          final rect = tester.getRect(find.byKey(Key(key)));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
        }
        await _capture(
          tester,
          'bom-edit-${size.width.toInt()}-${brightness.name}-2x',
        );
      });
    }
  }
}
