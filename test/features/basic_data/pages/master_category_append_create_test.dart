import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/pages/client_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/mould_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/supplier_category_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../support/audit_screenshot_support.dart';

const _category = '11111111-1111-4111-8111-111111111111';
const _unit = '22222222-2222-4222-8222-222222222222';
const _capture = bool.fromEnvironment('UTEN_CAPTURE_MASTER_TABLE');
final _captureKey = GlobalKey();

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api(this.domain) : super(Dio());
  final String domain;
  final writes = <Map<String, dynamic>>[];
  final writePaths = <String>[];

  Map<String, dynamic> get category => {
    'id': _category,
    'name': '录入分类',
    'code': 'TEST',
    'codePrefix': 'TEST',
    'effectivePrefix': 'TEST',
    'level': 0,
    'path': '录入分类',
    'children': <Object>[],
    'childCount': 0,
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/tree') || path.endsWith('/subtree')) return [category];
    if (path.contains('/units')) {
      return [
        {'id': _unit, 'name': '个', 'code': 'PCS', 'status': '使用'},
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/facets')) {
      return {'fields': <String, Object>{}, 'nullCounts': <String, int>{}};
    }
    if (path.endsWith('/$_category')) return category;
    if (path.endsWith('/prefix-availability') ||
        path.contains('identifier-availability')) {
      return {'available': true};
    }
    if (path == '/auth/me') {
      return {
        'session': {'preferences': <String, Object>{}},
      };
    }
    return {
      'items': <Object>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writePaths.add(path);
    final values = Map<String, dynamic>.from(body as Map);
    writes.add(values);
    return {
      ...values,
      'id': '33333333-3333-4333-8333-333333333333',
      'code': 'TEST001',
      'version': 0,
      'writable': true,
    };
  }
}

typedef _PageCase = ({
  String domain,
  String permission,
  String categoryPermission,
  Widget page,
});

Future<void> _open(
  WidgetTester tester,
  _PageCase entry,
  _Api api, {
  bool allowCreate = true,
  Size size = const Size(1600, 1000),
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (_capture) await loadAuditScreenshotFonts(tester);
  final theme = buildLightTheme();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'table-entry-test'),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          '${entry.permission}:view',
          if (allowCreate) '${entry.permission}:create',
          entry.categoryPermission,
        }),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        theme: _capture ? auditScreenshotTheme(theme) : theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => RepaintBoundary(
          key: _captureKey,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
        home: entry.page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (!tester.any(find.text('录入分类').hitTestable())) {
    await tester.tap(find.byIcon(Icons.account_tree_rounded));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('录入分类').hitTestable().first);
  await tester.pumpAndSettle();
}

Finder _newName() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.key is ValueKey<String> &&
      (widget.key as ValueKey<String>).value.startsWith(
        'inline-create-cell-',
      ) &&
      (widget.key as ValueKey<String>).value.endsWith('-name'),
);

/// 新建行内某文本字段的输入格；行按草稿顺序渲染，`.first` 即第一行。
Finder _newRowTextCell(String fieldKey) => find
    .byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.key is ValueKey<String> &&
          (widget.key as ValueKey<String>).value.startsWith(
            'inline-create-cell-',
          ) &&
          (widget.key as ValueKey<String>).value.endsWith('-$fieldKey'),
    )
    .first;

UtenDropdownField _newRowDropdown(
  WidgetTester tester,
  bool Function(UtenDropdownField) match,
) => tester.widget<UtenDropdownField>(
  find
      .byWidgetPredicate(
        (widget) => widget is UtenDropdownField && match(widget),
      )
      .first,
);

Future<void> _activateNewField(
  WidgetTester tester,
  String field, {
  String? draftKey,
}) async {
  final activate = find.byWidgetPredicate((widget) {
    if (widget.key is! ValueKey<String>) return false;
    final key = (widget.key as ValueKey<String>).value;
    return draftKey == null
        ? key.startsWith('inline-create-activate-') && key.endsWith('-$field')
        : key == 'inline-create-activate-$draftKey-$field';
  }).first;
  await tester.ensureVisible(activate);
  await tester.tap(activate);
  await tester.pumpAndSettle();
}

void main() {
  final cases = <_PageCase>[
    (
      domain: 'goods',
      permission: 'goods',
      categoryPermission: Perm.materialCategoryView,
      page: const ProductCategoryPage(),
    ),
    (
      domain: 'moulds',
      permission: 'mould',
      categoryPermission: Perm.mouldCategoryView,
      page: const MouldCategoryPage(),
    ),
    (
      domain: 'clients',
      permission: 'client',
      categoryPermission: Perm.clientCategoryView,
      page: const ClientCategoryPage(),
    ),
    (
      domain: 'suppliers',
      permission: 'supplier',
      categoryPermission: Perm.supplierCategoryView,
      page: const SupplierCategoryPage(),
    ),
  ];
  for (final entry in cases) {
    testWidgets(
      '${entry.domain} creates from a blank row in its selected category',
      (tester) async {
        final api = _Api(entry.domain);
        await _open(tester, entry, api);
        await tester.tap(find.text('编辑模式'));
        await tester.pumpAndSettle();
        expect(_newName(), findsNothing);
        expect(api.writes, isEmpty);
        await _activateNewField(tester, 'name');
        await tester.enterText(_newName().first, '表格新资料');
        await tester.pumpAndSettle();
        final nameKey =
            (tester.widget<TextField>(_newName().first).key as ValueKey<String>)
                .value;
        final draftKey = nameKey.substring(
          'inline-create-cell-'.length,
          nameKey.length - '-name'.length,
        );
        // 必填字段全部在可见列内，直接在新建行补齐（不再有「其他字段」弹窗入口）。
        if (entry.domain == 'goods') {
          await _activateNewField(tester, 'sourceType', draftKey: draftKey);
          _newRowDropdown(
            tester,
            (field) => field.items.any((item) => item.value == '采购'),
          ).onChanged('采购');
          await tester.pumpAndSettle();
          await _activateNewField(tester, 'unitId', draftKey: draftKey);
          _newRowDropdown(
            tester,
            (field) => field.items.any((item) => item.value == _unit),
          ).onChanged(_unit);
          await tester.pumpAndSettle();
        } else if (entry.domain == 'suppliers') {
          await _activateNewField(tester, 'linkman', draftKey: draftKey);
          await tester.enterText(_newRowTextCell('linkman'), '采购联系人');
          await tester.pumpAndSettle();
        }
        expect(api.writes, isEmpty, reason: 'input only stages a draft');
        if (_capture && entry.domain == 'goods') {
          for (final state in tester.stateList<ScrollableState>(
            find.byType(Scrollable),
          )) {
            if (state.position.axis == Axis.horizontal) {
              state.position.jumpTo(state.position.minScrollExtent);
            }
          }
          await tester.pumpAndSettle();
          await saveAuditScreenshot(
            tester,
            _captureKey,
            'goods-table-blank-entry',
          );
        }
        await tester.tap(find.text('保存 1 行修改'));
        await tester.pumpAndSettle();
        expect(api.writes, hasLength(1));
        expect(api.writePaths, ['/master/${entry.domain}']);
        expect(api.writes.single['categoryId'], _category);
        expect(api.writes.single['name'], '表格新资料');
        expect(api.writes.single.containsKey('id'), isFalse);
        if (entry.domain == 'goods') expect(api.writes.single['unitId'], _unit);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('view-only category has no edit or draft-row creation entry', (
    tester,
  ) async {
    final entry = cases.first;
    final api = _Api(entry.domain);
    await _open(tester, entry, api, allowCreate: false);
    expect(find.text('编辑模式'), findsNothing);
    expect(_newName(), findsNothing);
    expect(api.writes, isEmpty);
  });

  testWidgets('goods blank rows remain usable in a narrow enlarged page', (
    tester,
  ) async {
    final entry = cases.first;
    final api = _Api(entry.domain);
    await _open(tester, entry, api, size: const Size(390, 844), textScale: 2);
    await tester.ensureVisible(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await _activateNewField(tester, 'name');
    await tester.enterText(_newName().first, '窄屏新货品');
    await tester.pumpAndSettle();
    expect(api.writes, isEmpty);
    expect(tester.takeException(), isNull);
    if (_capture) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'goods-table-blank-entry-narrow',
      );
    }
  });
}
