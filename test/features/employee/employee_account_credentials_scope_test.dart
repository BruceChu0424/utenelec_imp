import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/employee/widgets/employee_credential_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

const _secret = 'Synthetic-Private-Once-Only!44';

class _Api extends Fake implements ApiClient {}

class _Actor extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'actor',
      code: 'HR1',
      name: '人事',
      permissions: [Perm.accountSupport],
    ),
  );
  void change() => state = const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'other',
      code: 'HR2',
      name: '另一人事',
      permissions: [Perm.accountSupport],
    ),
  );
}

Future<(ProviderContainer, GlobalKey<NavigatorState>)> _open(
  WidgetTester tester,
  ValueNotifier<int> owner,
  bool Function() current, {
  String? title,
}) async {
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(_Api()),
      sessionProvider.overrideWith(() => _Actor()),
    ],
  );
  addTearDown(container.dispose);
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navigator,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAccountCredentialDialog(
                context,
                temporaryPassword: _secret,
                title: title,
                loginAccount: '13800138000',
                employeeName: '合成员工',
                isCurrent: current,
                ownerChanges: owner,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.text(_secret), findsOneWidget);
  return (container, navigator);
}

void main() {
  testWidgets('同scope切目标后owner通知立即清空凭据且恢复原目标不复活', (tester) async {
    final owner = ValueNotifier(0);
    addTearDown(owner.dispose);
    var current = true;
    await _open(tester, owner, () => current);
    current = false;
    owner.value++;
    current = true;
    owner.value++;
    await tester.pumpAndSettle();
    expect(find.text(_secret), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('真实身份变化时即使caller尚未变更也关闭旧凭据', (tester) async {
    final owner = ValueNotifier(0);
    addTearDown(owner.dispose);
    final (container, _) = await _open(tester, owner, () => true);
    (container.read(sessionProvider.notifier) as _Actor).change();
    await tester.pumpAndSettle();
    expect(find.text(_secret), findsNothing);
  });

  testWidgets('owner失效移除自身凭据route不pop覆盖窗口', (tester) async {
    final owner = ValueNotifier(0);
    addTearDown(owner.dispose);
    var current = true;
    final (_, navigator) = await _open(tester, owner, () => current);
    showDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => const AlertDialog(content: Text('覆盖窗口')),
    );
    await tester.pumpAndSettle();
    current = false;
    owner.value++;
    await tester.pumpAndSettle();
    expect(find.text(_secret), findsNothing);
    expect(find.text('覆盖窗口'), findsOneWidget);
  });

  testWidgets('缓存复制回调在持有者失效后不写剪贴板', (tester) async {
    final owner = ValueNotifier(0);
    addTearDown(owner.dispose);
    var current = true;
    await _open(tester, owner, () => current);
    final writes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          writes.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final copy = tester
        .widget<TextButton>(find.widgetWithIcon(TextButton, Icons.copy_rounded))
        .onPressed!;
    current = false;
    copy();
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(find.text(_secret), findsNothing);
  });

  testWidgets('重置凭据可给真实标题且不冒称账号新建', (tester) async {
    final owner = ValueNotifier(0);
    addTearDown(owner.dispose);
    await _open(tester, owner, () => true, title: '一次性临时密码');
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('account-credential-title')))
          .data,
      '一次性临时密码',
    );
    expect(find.text('账号已创建'), findsNothing);
  });
}
