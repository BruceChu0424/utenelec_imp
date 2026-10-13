import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/font_scale_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _owner = StateProvider<String?>((ref) => null);

class _SessionStub extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
  void replace(SessionState next) => state = next;
}

class _DelayedPreferences extends FontScalePreferences {
  _DelayedPreferences(super.preferences);
  final writes = <({String key, String value, Completer<void> ready})>[];
  @override
  Future<bool> persistChoice(String key, String value) async {
    final ready = Completer<void>();
    writes.add((key: key, value: value, ready: ready));
    await ready.future;
    return super.persistChoice(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ProviderContainer, SharedPreferences)> containerWith(
    Map<String, Object> saved, {
    FontScalePreferences Function(SharedPreferences)? store,
  }) async {
    SharedPreferences.setMockInitialValues(saved);
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        fontScaleOwnerProvider.overrideWith((ref) => ref.watch(_owner)),
        if (store != null)
          fontScalePreferencesProvider.overrideWithValue(store(prefs)),
      ],
    );
    addTearDown(container.dispose);
    return (container, prefs);
  }

  test('未登录/退出后标准，旧全局值只迁移给首个账号，其他账号不继承', () async {
    final (container, prefs) = await containerWith({'fontScale': 'xxLarge'});
    expect(container.read(fontScaleProvider).isAuto, isTrue);
    expect(prefs.getString(FontScalePreferences.migrationKey), isNull);
    container.read(_owner.notifier).state = 'user-a';
    expect(container.read(fontScaleProvider).manual, FontScale.xxLarge);
    await Future<void>.delayed(Duration.zero);
    expect(
      prefs.getString(FontScalePreferences.migrationKey),
      contains('user-a'),
    );
    container.read(_owner.notifier).state = 'user-b';
    expect(container.read(fontScaleProvider).isAuto, isTrue);
    await container
        .read(fontScaleProvider.notifier)
        .set(const FontScaleChoice.manual(FontScale.large));
    container.read(_owner.notifier).state = null;
    expect(container.read(fontScaleProvider).isAuto, isTrue);
    container.read(_owner.notifier).state = 'user-a';
    expect(container.read(fontScaleProvider).manual, FontScale.xxLarge);
    container.read(_owner.notifier).state = 'user-b';
    expect(container.read(fontScaleProvider).manual, FontScale.large);
    expect(prefs.getString('fontScale'), 'xxLarge');
  });

  test('已有个人键优先，但首个账号仍认领旧值防止第二人回读', () async {
    final (container, prefs) = await containerWith({
      'fontScale': 'giant',
      FontScalePreferences.keyFor('user-a'): 'small',
    });
    container.read(_owner.notifier).state = 'user-a';
    expect(container.read(fontScaleProvider).manual, FontScale.small);
    container.read(_owner.notifier).state = 'user-b';
    expect(container.read(fontScaleProvider).isAuto, isTrue);
    expect(
      prefs.getString(FontScalePreferences.migrationKey),
      contains('user-a'),
    );
  });

  test('新容器重启恢复75%兼容档和每个人的独立选择', () async {
    final (container, prefs) = await containerWith({
      FontScalePreferences.keyFor('user-a'): 'xSmall',
      FontScalePreferences.keyFor('user-b'): 'giant',
    });
    container.read(_owner.notifier).state = 'user-a';
    expect(container.read(fontScaleProvider).factor, 0.75);
    final fresh = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        fontScaleOwnerProvider.overrideWithValue('user-b'),
      ],
    );
    addTearDown(fresh.dispose);
    expect(fresh.read(fontScaleProvider).factor, 2);
    await fresh
        .read(fontScaleProvider.notifier)
        .set(const FontScaleChoice.auto());
    expect(prefs.getString(FontScalePreferences.keyFor('user-b')), 'auto');
    expect(prefs.getString(FontScalePreferences.keyFor('user-a')), 'xSmall');
  });

  test('代操作偏好归真实操作者，档案刷新不切换归属', () {
    final container = ProviderContainer(
      overrides: [sessionProvider.overrideWith(_SessionStub.new)],
    );
    addTearDown(container.dispose);
    const admin = AppUser(id: 'admin', code: 'a', name: '管理员');
    const employee = AppUser(id: 'employee', code: 'e', name: '员工');
    final session = container.read(sessionProvider.notifier) as _SessionStub;
    session.replace(
      const SessionState(status: AuthStatus.authenticated, user: admin),
    );
    expect(container.read(fontScaleOwnerProvider), 'admin');
    session.replace(
      const SessionState(
        status: AuthStatus.authenticated,
        user: employee,
        actor: admin,
      ),
    );
    expect(container.read(fontScaleOwnerProvider), 'admin');
    session.replace(const SessionState());
    expect(container.read(fontScaleOwnerProvider), isNull);
  });

  test('账号A迟到写入不覆盖B或登出界面', () async {
    late _DelayedPreferences store;
    final (container, prefs) = await containerWith(
      {},
      store: (prefs) => store = _DelayedPreferences(prefs),
    );
    container.read(_owner.notifier).state = 'user-a';
    final writing = container
        .read(fontScaleProvider.notifier)
        .set(const FontScaleChoice.manual(FontScale.giant));
    await Future<void>.delayed(Duration.zero);
    expect(store.writes.single.key, FontScalePreferences.keyFor('user-a'));
    container.read(_owner.notifier).state = 'user-b';
    expect(container.read(fontScaleProvider).isAuto, isTrue);
    store.writes.single.ready.complete();
    await writing;
    expect(container.read(fontScaleProvider).isAuto, isTrue);
    expect(prefs.getString(FontScalePreferences.keyFor('user-a')), 'giant');
    expect(prefs.getString(FontScalePreferences.keyFor('user-b')), isNull);
    container.read(_owner.notifier).state = null;
    expect(container.read(fontScaleProvider).isAuto, isTrue);
  });

  test('连续选择按顺序持久化，旧异步结果不覆盖最新界面选择', () async {
    late _DelayedPreferences store;
    final (container, prefs) = await containerWith(
      {},
      store: (prefs) => store = _DelayedPreferences(prefs),
    );
    container.read(_owner.notifier).state = 'user-a';
    final notifier = container.read(fontScaleProvider.notifier);
    final first = notifier.set(const FontScaleChoice.manual(FontScale.large));
    final second = notifier.set(const FontScaleChoice.manual(FontScale.giant));
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, hasLength(1));
    store.writes[0].ready.complete();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, hasLength(2));
    store.writes[1].ready.complete();
    await second;
    expect(container.read(fontScaleProvider).manual, FontScale.giant);
    expect(prefs.getString(FontScalePreferences.keyFor('user-a')), 'giant');
  });

  test('损坏迁移记录或无效旧值不让新账号回读前人偏好', () async {
    final (container, _) = await containerWith({
      'fontScale': 'giant',
      FontScalePreferences.migrationKey: 'broken',
    });
    container.read(_owner.notifier).state = 'user-b';
    expect(container.read(fontScaleProvider).isAuto, isTrue);
  });

  test('dispose后迟到写入安全完成，不能触碰已销毁provider', () async {
    late _DelayedPreferences store;
    final (container, _) = await containerWith(
      {},
      store: (prefs) => store = _DelayedPreferences(prefs),
    );
    container.read(_owner.notifier).state = 'user-a';
    final writing = container
        .read(fontScaleProvider.notifier)
        .set(const FontScaleChoice.manual(FontScale.huge));
    await Future<void>.delayed(Duration.zero);
    container.dispose();
    store.writes.single.ready.complete();
    await writing;
  });
}
