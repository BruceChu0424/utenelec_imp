import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_form_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('UTEN_GOODS_SYSTEM_ID_SCREENSHOT');
const _uuid = '28f28034-9021-4a91-9727-55b16979b7e2';
const _identityKey = ValueKey('goods-system-identity');
const _copyKey = ValueKey('goods-system-identity-copy');
final _captureKey = GlobalKey();

GoodsDetail _detail({bool writable = false}) => GoodsDetail(
  id: _uuid,
  legacyId: 712,
  code: 'P-001',
  name: '测试货品',
  status: '使用',
  sourceType: '自制',
  writable: writable,
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  GoodsDetail? detail,
  bool create = false,
  bool canEdit = false,
  Size size = const Size(1440, 900),
  double textScale = 1,
  bool dark = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (_capture) await loadAuditScreenshotFonts(tester);
  final theme = dark ? buildDarkTheme() : buildLightTheme();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          if (create) Perm.goodsCreate,
          if (canEdit) Perm.goodsEdit,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        authenticatedScopeProvider.overrideWithValue(null),
        colorDictProvider.overrideWith((ref) async => const []),
        unitDictProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: _capture ? auditScreenshotTheme(theme) : theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: RepaintBoundary(key: _captureKey, child: child!),
        ),
        home: Scaffold(
          body: GoodsDetailBody(
            initialDetail: create ? null : detail ?? _detail(),
            initialCategoryId: create ? 'category-new' : null,
            canCreate: create,
            canEdit: canEdit,
            canStatus: false,
            canBomCreate: false,
            canBomEdit: false,
            canBomDelete: false,
            onToggleStatus: null,
            onDelete: null,
            onDataChanged: null,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(GoodsDetailBody)),
    listen: false,
  );
}

class _Clipboard {
  _Clipboard(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final value = (call.arguments as Map)['text'] as String;
        attemptedValues.add(value);
        if (failWrites) throw PlatformException(code: 'clipboard-unavailable');
        text = value;
      }
      if (call.method == 'Clipboard.getData') return {'text': text};
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  String text = 'existing clipboard';
  bool failWrites = false;
  final attemptedValues = <String>[];
}

void main() {
  testWidgets('系统标识位于基础信息首格并提供完整 UUID 提示', (tester) async {
    await _pump(tester);
    final grid = tester.widget<UtenFormGrid>(find.byType(UtenFormGrid).first);
    expect(grid.children.first.key, _identityKey);
    final identity = find.byKey(_identityKey);
    expect(
      find.descendant(of: identity, matching: find.text('系统标识')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: identity,
        matching: find.byWidgetPredicate(
          (widget) => widget is Tooltip && widget.message == _uuid,
        ),
      ),
      findsOneWidget,
    );
    final copy = tester.widget<IconButton>(find.byKey(_copyKey));
    expect(copy.tooltip, '复制系统标识');
    expect(copy.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    if (_capture) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'goods-system-identity-desktop',
      );
    }
  });

  for (final writable in [false, true]) {
    testWidgets('仅查看授权可复制完整 UUID，货品可写=$writable', (tester) async {
      final clipboard = _Clipboard(tester);
      final container = await _pump(
        tester,
        detail: _detail(writable: writable),
      );
      expect(find.text('编辑'), findsNothing);
      await tester.tap(find.byKey(_copyKey));
      await tester.pumpAndSettle();
      expect(clipboard.attemptedValues, [_uuid]);
      expect((await Clipboard.getData('text/plain'))?.text, _uuid);
      final notice = container.read(appNotificationProvider).single;
      expect(notice.kind, AppNotificationKind.success);
      expect(notice.message, '系统标识已复制');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('390dp 深色 200% 字号的复制图标可见且复制不截断', (tester) async {
    final clipboard = _Clipboard(tester);
    await _pump(tester, size: const Size(390, 900), textScale: 2, dark: true);
    final identity = find.byKey(_identityKey);
    final copy = find.byKey(_copyKey);
    expect(copy.hitTestable(), findsOneWidget);
    final cardRect = tester.getRect(identity);
    final copyRect = tester.getRect(copy);
    expect(copyRect.left, greaterThanOrEqualTo(cardRect.left));
    expect(copyRect.right, lessThanOrEqualTo(cardRect.right));
    expect(copyRect.bottom, lessThanOrEqualTo(900));
    final value = tester.widget<Text>(
      find.descendant(of: identity, matching: find.text(_uuid)),
    );
    expect(value.maxLines, 1);
    expect(value.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
    if (_capture) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'goods-system-identity-narrow-dark-200',
      );
    }
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(clipboard.text, _uuid);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新增态不显示伪造 UUID 或标识编辑字段', (tester) async {
    await _pump(tester, create: true);
    expect(find.byKey(_identityKey), findsNothing);
    expect(find.byKey(_copyKey), findsNothing);
    expect(find.text('系统标识'), findsNothing);
    final form = tester.widget<MasterEditForm>(find.byType(MasterEditForm));
    expect(
      form.fields.where((field) => const {'id', 'goodsId'}.contains(field.key)),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('剪贴板失败给出提示且可直接重试复制', (tester) async {
    final clipboard = _Clipboard(tester)..failWrites = true;
    final container = await _pump(tester);
    final copy = find.byKey(_copyKey);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(clipboard.text, 'existing clipboard');
    final failure = container.read(appNotificationProvider).single;
    expect(failure.kind, AppNotificationKind.error);
    expect(failure.message, '系统标识复制失败，请重试');
    expect(tester.takeException(), isNull);
    clipboard.failWrites = false;
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(clipboard.attemptedValues, [_uuid, _uuid]);
    expect(clipboard.text, _uuid);
    expect(
      container.read(appNotificationProvider).last.kind,
      AppNotificationKind.success,
    );
    expect(tester.takeException(), isNull);
  });
}
