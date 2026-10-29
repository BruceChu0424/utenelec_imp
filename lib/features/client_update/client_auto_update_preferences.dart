import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/shared_providers.dart';

const clientAutoUpdatePreferenceKey = 'clientUpdate.autoWhenIdle';

class ClientAutoUpdatePreference extends Notifier<bool> {
  @override
  bool build() =>
      ref
          .watch(sharedPreferencesProvider)
          .getBool(clientAutoUpdatePreferenceKey) ??
      true;

  Future<void> setEnabled(bool enabled) async {
    final previous = state;
    state = enabled;
    try {
      final saved = await ref
          .read(sharedPreferencesProvider)
          .setBool(clientAutoUpdatePreferenceKey, enabled);
      if (!saved) throw StateError('无法保存自动更新设置');
    } catch (_) {
      state = previous;
      rethrow;
    }
  }
}

final clientAutoUpdateEnabledProvider =
    NotifierProvider<ClientAutoUpdatePreference, bool>(
      ClientAutoUpdatePreference.new,
    );
