import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/client_update/client_auto_update_preferences.dart';
import 'package:uten_imp/features/client_update/client_release.dart';
import 'package:uten_imp/features/client_update/client_staged_update.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _endpoint = StateProvider((ref) => 'https://one.test/api');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'automatic idle update defaults on and an explicit opt-out survives reopening',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final first = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      );
      expect(first.read(clientAutoUpdateEnabledProvider), isTrue);
      await first
          .read(clientAutoUpdateEnabledProvider.notifier)
          .setEnabled(false);
      first.dispose();
      final reopened = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      );
      addTearDown(reopened.dispose);
      expect(reopened.read(clientAutoUpdateEnabledProvider), isFalse);
      await reopened
          .read(clientAutoUpdateEnabledProvider.notifier)
          .setEnabled(true);
      expect(preferences.getBool(clientAutoUpdatePreferenceKey), isTrue);
    },
  );

  test(
    'changing endpoint removes the previous verified package and eligibility',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'uten-stage-endpoint-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final package = File('${directory.path}/verified.zip');
      await package.writeAsBytes([1, 2, 3]);
      final container = ProviderContainer(
        overrides: [
          apiBaseUrlProvider.overrideWith((ref) => ref.watch(_endpoint)),
        ],
      );
      addTearDown(container.dispose);
      final previous = container.read(clientStagedUpdateStoreProvider);
      previous.stage(
        StagedClientUpdate(
          endpoint: 'https://one.test/api',
          path: package.path,
          release: const ClientRelease(
            id: 'stage',
            platform: 'windows',
            architecture: 'x64',
            version: '2.0.0',
            buildNumber: 2,
            releaseNotes: '',
            installMode: 'windows_archive',
          ),
          context: const ClientInstallContext(
            platform: 'windows',
            architecture: 'x64',
            currentVersion: '1.0.0',
            currentBuild: 1,
            supportsInPlaceUpdate: true,
          ),
        ),
      );
      container.read(_endpoint.notifier).state = 'https://two.test/api';
      final current = container.read(clientStagedUpdateStoreProvider);
      expect(identical(previous, current), isFalse);
      expect(current.update, isNull);
      expect(previous.update, isNull);
      for (var attempt = 0; attempt < 20 && await package.exists(); attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await package.exists(), isFalse);
    },
  );
}
