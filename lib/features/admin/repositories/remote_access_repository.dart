import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';

class RemoteAccessPolicy {
  const RemoteAccessPolicy({
    required this.enabled,
    required this.maxUsers,
    required this.version,
  });
  final bool enabled;
  final int maxUsers, version;
  factory RemoteAccessPolicy.fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'];
    final maxUsers = json['maxUsers'];
    final version = json['version'];
    if (enabled is! bool ||
        maxUsers is! int ||
        maxUsers < 1 ||
        version is! int ||
        version < 0) {
      throw const FormatException('Invalid remote access policy');
    }
    return RemoteAccessPolicy(
      enabled: enabled,
      maxUsers: maxUsers,
      version: version,
    );
  }
}

class RemoteAccessUser {
  const RemoteAccessUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.mfaEnabled,
    required this.remoteAccess,
  });
  final String id, username, displayName;
  final bool mfaEnabled, remoteAccess;
  factory RemoteAccessUser.fromJson(Map<String, dynamic> json) =>
      RemoteAccessUser(
        id: json['id'] as String,
        username: json['username'] as String,
        displayName: json['displayName'] as String,
        mfaEnabled: json['mfaEnabled'] as bool,
        remoteAccess: json['remoteAccess'] as bool,
      );
}

class RemoteAccessStatus {
  const RemoteAccessStatus({
    required this.policy,
    required this.authorizedUsers,
    required this.authorizedCount,
    required this.remoteChannelConfigured,
    required this.currentAccessChannel,
    required this.observedAt,
    required this.deploymentId,
  });
  final RemoteAccessPolicy policy;
  final List<RemoteAccessUser> authorizedUsers;
  final int authorizedCount;
  final bool remoteChannelConfigured;
  final String currentAccessChannel, deploymentId;
  final DateTime observedAt;
  factory RemoteAccessStatus.fromJson(Map<String, dynamic> json) {
    final channel = json['currentAccessChannel'];
    if (channel != 'local' && channel != 'remote') {
      throw const FormatException('Unverified access channel');
    }
    return RemoteAccessStatus(
      policy: RemoteAccessPolicy.fromJson(
        json['policy'] as Map<String, dynamic>,
      ),
      authorizedUsers: (json['authorizedUsers'] as List)
          .map((e) => RemoteAccessUser.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      authorizedCount: json['authorizedCount'] as int,
      remoteChannelConfigured: json['remoteChannelConfigured'] as bool,
      currentAccessChannel: channel as String,
      observedAt: DateTime.parse(json['observedAt'] as String),
      deploymentId: json['deploymentId'] as String,
    );
  }
}

abstract interface class RemoteAccessRepository {
  Future<RemoteAccessStatus> status();
  Future<void> save({
    required bool enabled,
    required int maxUsers,
    required int expectedVersion,
  });
  Future<void> revoke(String userId);
  Future<void> resetMfa(String userId, String reason);
}

class DioRemoteAccessRepository implements RemoteAccessRepository {
  DioRemoteAccessRepository(this.api);
  final ApiClient api;
  @override
  Future<RemoteAccessStatus> status() async =>
      RemoteAccessStatus.fromJson(await api.get('/admin/remote-access/status'));
  @override
  Future<void> save({
    required bool enabled,
    required int maxUsers,
    required int expectedVersion,
  }) async {
    if (maxUsers < 1 || maxUsers > 10000 || expectedVersion < 0) {
      throw const FormatException('Invalid remote access policy');
    }
    await api.patch(
      '/admin/remote-access/policy',
      body: {
        'enabled': enabled,
        'maxUsers': maxUsers,
        'expectedVersion': expectedVersion,
      },
    );
  }

  @override
  Future<void> revoke(String userId) async => api.put(
    '/admin/users/${Uri.encodeComponent(userId)}/remote-access',
    body: {'remoteAccess': false},
  );
  @override
  Future<void> resetMfa(String userId, String reason) async {
    if (reason.trim().isEmpty || reason.length > 256) {
      throw const FormatException('Reset reason is required');
    }
    final result = await api.post(
      '/auth/mfa/users/${Uri.encodeComponent(userId)}/reset',
      body: {'reason': reason.trim()},
    );
    if (result['reauthenticationRequired'] != true) {
      throw const FormatException('Reset was not confirmed');
    }
  }
}

final remoteAccessRepositoryProvider = Provider<RemoteAccessRepository>(
  (ref) => DioRemoteAccessRepository(ref.watch(apiClientProvider)),
);
