// 断网恢复不重建网络层(ADR-108 / perf-frontend-07): recoveryEpoch 推进后 Dio 与名称服务
// 实例保持不变(此前 apiClientProvider watch recoveryEpoch, 恢复时约 90 个 provider 整体重建,
// 字典缓存全丢再重拉)。恢复后的补拉由各页面「返回即刷新」与徽章汇总各自负责。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/shared/providers/master_dictionary_repository.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('recoveryEpoch bump keeps the Dio client and name services', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final recovery = ConnectionRecoveryController(
      probe: () async => true,
      probeDelays: const <Duration>[Duration(milliseconds: 1)],
      restoredDisplayDuration: Duration.zero,
    );
    final container = ProviderContainer(
      overrides: <Override>[
        secureStorageProvider.overrideWithValue(
          SecureStorage(const FlutterSecureStorage()),
        ),
        connectionRecoveryProvider.overrideWith((ref) => recovery),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
    );
    addTearDown(container.dispose);

    final api = container.read(apiClientProvider);
    final names = container.read(masterNameServiceProvider);
    final dictionaries = container.read(masterDictionaryRepositoryProvider);
    final epochBefore = recovery.state.recoveryEpoch;

    recovery.markDisconnected();
    recovery.markConnected();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(recovery.state.recoveryEpoch, greaterThan(epochBefore));
    expect(identical(container.read(apiClientProvider), api), isTrue);
    expect(identical(container.read(masterNameServiceProvider), names), isTrue);
    expect(
      identical(
        container.read(masterDictionaryRepositoryProvider),
        dictionaries,
      ),
      isTrue,
    );
  });
}
