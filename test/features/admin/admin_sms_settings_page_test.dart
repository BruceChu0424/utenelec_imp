import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/models/sms_settings.dart';
import 'package:uten_imp/features/admin/pages/admin_sms_settings_page.dart';
import 'package:uten_imp/features/admin/providers/server_operations_access.dart';
import 'package:uten_imp/features/admin/repositories/sms_settings_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/audit_screenshot_support.dart';

void main() {
  testWidgets(
    'SMS endpoint menu survives narrow large-text resize without saving or losing edits',
    (tester) async {
      final scale = ValueNotifier<double>(1);
      addTearDown(scale.dispose);
      final repository = _Repository();
      await _pump(tester, repository, textScale: scale);
      await tester.enterText(
        find.byKey(const ValueKey('sms-key-id')),
        'resize-draft',
      );
      await tester.tap(find.byKey(const ValueKey('sms-endpoint-options')));
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<String>), findsWidgets);
      tester.view.physicalSize = const Size(260, 900);
      scale.value = 2;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(PopupMenuItem<String>), findsWidgets);
      expect(repository.commands, isEmpty);
      tester.view.physicalSize = const Size(1440, 1100);
      scale.value = 1;
      await tester.pumpAndSettle();
      await tester.tap(find.text('dysmsapi.ap-southeast-1.aliyuncs.com').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('sms-key-id')))
            .controller!
            .text,
        'resize-draft',
      );
      expect(repository.reads, 1);
      expect(repository.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an empty disabled first-company gateway can be saved without an endpoint or credentials',
    (tester) async {
      final repository = _Repository()
        ..value = _settings(
          provider: 'DISABLED',
          configured: false,
          endpoint: '',
        );
      await _pump(tester, repository);
      await _save(tester);
      expect(repository.commands.single['provider'], 'DISABLED');
      expect(repository.commands.single['endpoint'], '');
      expect(repository.commands.single.containsKey('accessKeyId'), false);
      expect(repository.commands.single.containsKey('accessKeySecret'), false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'server endpoint list rejects OSS-shaped, protocol and port destinations',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      for (final endpoint in [
        'dysmsapi.oss-cn-hangzhou.aliyuncs.com',
        'dysmsapi.cn-hangzhou.aliyuncs.com',
        'https://dysmsapi.aliyuncs.com',
        'dysmsapi.aliyuncs.com:443',
      ]) {
        await tester.enterText(
          find.byKey(const ValueKey('sms-endpoint')),
          endpoint,
        );
        await _save(tester);
        expect(repository.commands, isEmpty);
        expect(
          tester
              .state<FormFieldState<String>>(
                find.byKey(const ValueKey('sms-endpoint')),
              )
              .errorText,
          '请选择服务器允许的官方短信接口域名。',
        );
        expect(find.byTooltip(RegExp('请选择服务器允许的官方短信接口域名')), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'invalid environment endpoint remains visible and can be replaced with a server-listed VPC endpoint',
    (tester) async {
      const vpc = 'dysmsapi-xman.vpc-proxy.aliyuncs.com';
      final repository = _Repository()
        ..value = _settings(
          endpoint: 'dysmsapi.oss-cn-hangzhou.aliyuncs.com',
          status: 'INVALID',
        );
      await _pump(tester, repository);
      expect(find.text('配置状态：配置无效'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('sms-endpoint')))
            .controller!
            .text,
        'dysmsapi.oss-cn-hangzhou.aliyuncs.com',
      );
      await tester.tap(find.byKey(const ValueKey('sms-endpoint-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(vpc).last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sms-key-id')), 'newId');
      await tester.enterText(
        find.byKey(const ValueKey('sms-secret')),
        'typedSecret',
      );
      await _save(tester);
      expect(repository.commands.single['endpoint'], vpc);
      expect(repository.commands.single['accessKeyId'], 'newId');
      expect(repository.commands.single['accessKeySecret'], 'typedSecret');
      expect(repository.reads, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'missing server endpoint authority never falls back to a regional wildcard',
    (tester) async {
      final repository = _Repository()
        ..value = _settings(allowedEndpoints: const []);
      await _pump(tester, repository);
      await _save(tester);
      expect(repository.commands, isEmpty);
      expect(
        tester
            .state<FormFieldState<String>>(
              find.byKey(const ValueKey('sms-endpoint')),
            )
            .errorText,
        '服务器未提供短信接口允许列表，请重新读取配置后重试。',
      );
      expect(find.byTooltip(RegExp('服务器未提供短信接口允许列表')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'SMS endpoint options are the immutable server response including VPC hosts',
    () {
      final settings = _settings();
      expect(settings.allowedEndpoints, _allowedEndpoints);
      expect(
        () => settings.allowedEndpoints.add(
          'dysmsapi.oss-cn-hangzhou.aliyuncs.com',
        ),
        throwsUnsupportedError,
      );
      expect(_settings(allowedEndpoints: const []).allowedEndpoints, isEmpty);
    },
  );
  testWidgets(
    'a new company can save a disabled gateway domain before providing credentials',
    (tester) async {
      final repository = _Repository()
        ..value = _settings(provider: 'DISABLED', configured: false);
      await _pump(tester, repository);
      await tester.enterText(
        find.byKey(const ValueKey('sms-endpoint')),
        'dysmsapi.ap-southeast-1.aliyuncs.com',
      );
      await _save(tester);
      expect(repository.commands.single['provider'], 'DISABLED');
      expect(repository.commands.single.containsKey('accessKeyId'), false);
      expect(repository.commands.single.containsKey('accessKeySecret'), false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'late configuration from a previous administrator cannot overwrite the current company',
    (tester) async {
      final owner = StateProvider<Object?>((ref) => 'company-a/admin');
      final pending = Completer<SmsSettings>();
      final repository = _Repository()..handler = () => pending.future;
      await _pump(tester, repository, owner: owner, settle: false);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
        listen: false,
      );
      repository.handler = () async => _settings(source: 'DATABASE');
      container.read(owner.notifier).state = 'company-b/admin';
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('配置来源：数据库覆盖'), findsOneWidget);
      pending.complete(_settings());
      await tester.pumpAndSettle();
      expect(find.text('配置来源：数据库覆盖'), findsOneWidget);
      expect(find.text('配置来源：部署环境'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('SMS route needs both superadmin and authorization management', () {
    for (final admin in [false, true]) {
      for (final grant in [false, true]) {
        final permissions = grant ? [Perm.authorizationManage] : <String>[];
        final user = AppUser(
          id: 'u',
          code: 'U',
          name: '用户',
          superAdmin: admin,
          permissions: permissions,
        );
        expect(
          employeePermissionRedirect(user, RouteName.adminSmsSettings),
          admin && grant ? isNull : RouteName.accessDenied,
        );
        expect(
          locationAllowedFor(
            permissions.toSet(),
            admin,
            RouteName.adminSmsSettings,
          ),
          admin && grant,
        );
      }
    }
  });
  testWidgets(
    'unauthorized page does not read or write gateway configuration',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository, allowed: false);
      expect(repository.reads, 0);
      expect(repository.commands, isEmpty);
      expect(find.text('仅超级管理员可管理短信网关'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'production never offers log gateway or code exposure; blank keys retain the configured pair',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.tap(find.byKey(const ValueKey('sms-provider')));
      await tester.pumpAndSettle();
      expect(find.text('开发日志'), findsNothing);
      expect(find.textContaining('显示验证码'), findsNothing);
      await tester.tap(find.text('阿里云短信').last);
      await tester.pumpAndSettle();
      final secret = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('sms-secret')),
          matching: find.byType(TextField),
        ),
      );
      expect(secret.obscureText, true);
      expect(secret.controller!.text, isEmpty);
      await _save(tester);
      expect(repository.commands.single.containsKey('accessKeyId'), false);
      expect(repository.commands.single.containsKey('accessKeySecret'), false);
      expect(repository.commands.single['expectedRevision'], 'r1');
      expect(find.text('配置来源：数据库覆盖'), findsOneWidget);
      expect(
        repository.reads,
        1,
        reason:
            'saving a gateway does not send a test SMS or poll other services',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'partial credential or endpoint change cannot send the old key to a new destination',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.enterText(find.byKey(const ValueKey('sms-key-id')), 'newid');
      await _save(tester);
      expect(repository.commands, isEmpty);
      expect(find.text('更换访问凭据时，请同时填写新的密钥 ID 和密钥。'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('sms-key-id')), '');
      await tester.enterText(
        find.byKey(const ValueKey('sms-endpoint')),
        'dysmsapi.ap-southeast-1.aliyuncs.com',
      );
      await _save(tester);
      expect(repository.commands, isEmpty);
      expect(find.text('更换接口域名时需重新填写两项凭据，或明确清除凭据并停用。'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('sms-key-id')), 'newid');
      await tester.enterText(
        find.byKey(const ValueKey('sms-secret')),
        'typedSecret',
      );
      await _save(tester);
      expect(repository.commands.single['accessKeyId'], 'newid');
      expect(repository.commands.single['accessKeySecret'], 'typedSecret');
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('sms-secret')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'explicit credential clearing disables SMS and never sends mixed new credentials',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.enterText(find.byKey(const ValueKey('sms-key-id')), 'newid');
      await tester.enterText(
        find.byKey(const ValueKey('sms-secret')),
        'typedSecret',
      );
      await tester.ensureVisible(find.text('明确清除已保存凭据并停用短信'));
      await tester.tap(find.text('明确清除已保存凭据并停用短信'));
      await tester.pump();
      await _save(tester);
      expect(repository.commands.single['provider'], 'DISABLED');
      expect(repository.commands.single['clearCredentials'], true);
      expect(repository.commands.single.containsKey('accessKeyId'), false);
      expect(repository.commands.single.containsKey('accessKeySecret'), false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'restoring environment is an explicit separate command with no gateway/credential draft',
    (tester) async {
      final repository = _Repository()..value = _settings(source: 'DATABASE');
      await _pump(tester, repository);
      await tester.ensureVisible(
        find.byKey(const ValueKey('sms-settings-env')),
      );
      await tester.tap(find.byKey(const ValueKey('sms-settings-env')));
      await tester.pumpAndSettle();
      expect(repository.commands, isEmpty);
      await tester.tap(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.text('恢复部署配置'),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(repository.commands.single, {
        'expectedRevision': 'r1',
        'useEnvironment': true,
      });
      expect(find.text('配置来源：部署环境'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'unknown save result locks resubmission until authoritative reload',
    (tester) async {
      final repository = _Repository()
        ..saveError = NetworkException('not a real network');
      await _pump(tester, repository);
      await _save(tester);
      expect(
        tester
            .widget<UtenButton>(find.byKey(const ValueKey('sms-settings-save')))
            .onPressed,
        isNull,
      );
      expect(find.text('保存结果尚未确认，请重新读取服务器配置核对后再操作。'), findsOneWidget);
      repository.saveError = null;
      await tester.tap(find.byTooltip('重新读取服务器配置'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenButton>(find.byKey(const ValueKey('sms-settings-save')))
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final compact in [false, true]) {
    testWidgets(
      '${compact ? '375 dark large' : '1440 light'} SMS settings render',
      (tester) async {
        await loadAuditScreenshotFonts(tester);
        final key = GlobalKey();
        final repository = _Repository();
        await _pump(tester, repository, compact: compact, capture: key);
        expect(tester.takeException(), isNull);
        if (Platform.environment['UTEN_UI_FIXTURES'] == '1') {
          await saveAuditScreenshot(
            tester,
            key,
            compact
                ? 'server-settings-sms-375-dark-large-demo'
                : 'server-settings-sms-1440-light-demo',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

Future<void> _save(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('sms-settings-save')));
  await tester.tap(find.byKey(const ValueKey('sms-settings-save')));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repository, {
  bool allowed = true,
  bool compact = false,
  GlobalKey? capture,
  StateProvider<Object?>? owner,
  bool settle = true,
  ValueNotifier<double>? textScale,
}) async {
  tester.view.physicalSize = compact
      ? const Size(375, 1100)
      : const Size(1440, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        serverOperationsOwnerProvider.overrideWith(
          (ref) => owner == null ? 'company/admin' : ref.watch(owner),
        ),
        serverSourceVisibleProvider.overrideWithValue(allowed),
        serverOperationsWritableProvider.overrideWithValue(true),
        smsSettingsRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: auditScreenshotTheme(
          compact ? buildDarkTheme() : buildLightTheme(),
        ),
        builder: (context, child) => ValueListenableBuilder<double>(
          valueListenable:
              textScale ?? AlwaysStoppedAnimation(compact ? 1.4 : 1),
          builder: (context, scale, _) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: capture == null
                ? child!
                : RepaintBoundary(key: capture, child: child!),
          ),
        ),
        home: const AdminSmsSettingsPage(),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

const _allowedEndpoints = [
  'dysmsapi.aliyuncs.com',
  'dysmsapi.ap-southeast-1.aliyuncs.com',
  'dysmsapi.ap-southeast-5.aliyuncs.com',
  'dysmsapi.eu-central-1.aliyuncs.com',
  'dysmsapi-xman.vpc-proxy.aliyuncs.com',
  'dysmsapi-xman-vpc.ap-southeast-5.aliyuncs.com',
  'dysmsapi-xman-vpc.eu-central-1.aliyuncs.com',
];

SmsSettings _settings({
  String source = 'ENV',
  String revision = 'r1',
  String provider = 'ALIYUN',
  bool configured = true,
  String endpoint = 'dysmsapi.aliyuncs.com',
  String? status,
  List<String> allowedEndpoints = _allowedEndpoints,
}) => SmsSettings.fromJson({
  'revision': revision,
  'version': 1,
  'source': source,
  'provider': provider,
  'effectiveProvider': provider,
  'endpoint': endpoint,
  'allowedEndpoints': allowedEndpoints,
  'signName': '测试公司签名',
  'templateCode': 'SMS_TEST_DEMO',
  'accessKeyConfigured': configured,
  'accessKeyIdHint': '****1234',
  'secretUnreadable': false,
  'capabilities': {
    'canManage': true,
    'canUseLog': false,
    'canExposeCode': false,
  },
  'status': status ?? (provider == 'DISABLED' ? 'DISABLED' : 'READY'),
  'detail': '配置就绪，保存后下一次发码使用当前配置。',
  'applyMode': 'NEXT_ISSUANCE',
});

class _Repository implements SmsSettingsRepository {
  SmsSettings value = _settings();
  int reads = 0;
  Object? saveError;
  Future<SmsSettings> Function()? handler;
  final commands = <Map<String, dynamic>>[];
  @override
  Future<SmsSettings> fetch() async {
    reads++;
    return handler == null ? value : handler!();
  }

  @override
  Future<SmsSettings> save(Map<String, dynamic> command) async {
    commands.add(Map.of(command));
    if (saveError != null) throw saveError!;
    value = _settings(
      source: command['useEnvironment'] == true ? 'ENV' : 'DATABASE',
      revision: 'r2',
      provider: command['provider'] as String? ?? 'ALIYUN',
      configured: command['clearCredentials'] != true,
    );
    return value;
  }
}
