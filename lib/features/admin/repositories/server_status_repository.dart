import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/server_status.dart';

class ServerStatusRepository {
  ServerStatusRepository(this.api);
  final ApiClient api;

  Future<ServerStatusSnapshot> load() async =>
      ServerStatusSnapshot.fromJson(await api.get('/admin/server-status'));
}

final serverStatusRepositoryProvider = Provider<ServerStatusRepository>(
  (ref) => ServerStatusRepository(ref.watch(apiClientProvider)),
);
