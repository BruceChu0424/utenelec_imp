import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/sms_settings.dart';

abstract interface class SmsSettingsRepository {
  Future<SmsSettings> fetch();
  Future<SmsSettings> save(Map<String, dynamic> command);
}

final smsSettingsRepositoryProvider = Provider<SmsSettingsRepository>(
  (ref) => DioSmsSettingsRepository(ref.watch(apiClientProvider)),
);

class DioSmsSettingsRepository implements SmsSettingsRepository {
  DioSmsSettingsRepository(this.api);
  final ApiClient api;
  static const path = '/admin/sms-settings';
  @override
  Future<SmsSettings> fetch() async =>
      SmsSettings.fromJson(await api.get(path));
  @override
  Future<SmsSettings> save(Map<String, dynamic> command) async {
    final saved = SmsSettings.fromJson(await api.put(path, body: command));
    if (saved.revision == command['expectedRevision']) {
      throw const FormatException('SMS settings save has no new revision');
    }
    return saved;
  }
}
