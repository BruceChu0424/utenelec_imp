import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

class RemoteMfaStatus {
  const RemoteMfaStatus({
    required this.enabled,
    required this.pending,
    required this.sessionVerified,
    required this.enrollmentAllowed,
    required this.remoteRequest,
    this.pendingExpiresAt,
    this.sessionVerifiedUntil,
  });
  final bool enabled,
      pending,
      sessionVerified,
      enrollmentAllowed,
      remoteRequest;
  final DateTime? pendingExpiresAt, sessionVerifiedUntil;
  factory RemoteMfaStatus.fromJson(Map<String, dynamic> json) =>
      RemoteMfaStatus(
        enabled: json['enabled'] as bool,
        pending: json['pending'] as bool,
        sessionVerified: json['sessionVerified'] as bool,
        enrollmentAllowed: json['enrollmentAllowed'] as bool,
        remoteRequest: json['remoteRequest'] as bool,
        pendingExpiresAt: _date(json['pendingExpiresAt']),
        sessionVerifiedUntil: _date(json['sessionVerifiedUntil']),
      );
  static DateTime? _date(Object? value) =>
      value == null ? null : DateTime.parse(value as String);
}

/// Never persisted, logged or included in a draft/model toString.
class RemoteMfaEnrollment {
  const RemoteMfaEnrollment({
    required this.secret,
    required this.otpauthUri,
    required this.expiresAt,
  });
  final String secret, otpauthUri;
  final DateTime expiresAt;
  factory RemoteMfaEnrollment.fromJson(Map<String, dynamic> json) {
    final uri = json['otpauthUri'] as String;
    if (json['secret'] is! String ||
        (json['secret'] as String).isEmpty ||
        Uri.tryParse(uri)?.scheme != 'otpauth') {
      throw const FormatException('Invalid authenticator setup response');
    }
    return RemoteMfaEnrollment(
      secret: json['secret'] as String,
      otpauthUri: uri,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }
}

abstract interface class RemoteMfaRepository {
  Future<RemoteMfaStatus> status();
  Future<RemoteMfaEnrollment> enroll();
  Future<RemoteMfaStatus> confirm(String otpCode);
  Future<void> disable(String otpCode);
  Future<DateTime> verify(String otpCode);
}

class DioRemoteMfaRepository implements RemoteMfaRepository {
  DioRemoteMfaRepository(this.api);
  final ApiClient api;
  static const path = '/auth/mfa';
  @override
  Future<RemoteMfaStatus> status() async =>
      RemoteMfaStatus.fromJson(await api.get(path));
  @override
  Future<RemoteMfaEnrollment> enroll() async => RemoteMfaEnrollment.fromJson(
    await api.post('$path/enrollment', body: const <String, dynamic>{}),
  );
  @override
  Future<RemoteMfaStatus> confirm(String otpCode) async =>
      RemoteMfaStatus.fromJson(
        await api.post('$path/confirm', body: _code(otpCode)),
      );
  @override
  Future<void> disable(String otpCode) async {
    final json = await api.post('$path/disable', body: _code(otpCode));
    if (json['reauthenticationRequired'] != true) {
      throw const FormatException('Authenticator removal was not confirmed');
    }
  }

  @override
  Future<DateTime> verify(String otpCode) async {
    final json = await api.post('$path/verify', body: _code(otpCode));
    return DateTime.parse(json['verifiedUntil'] as String);
  }

  static Map<String, String> _code(String code) {
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const FormatException('A six digit code is required');
    }
    return {'otpCode': code};
  }
}

final remoteMfaRepositoryProvider = Provider<RemoteMfaRepository>(
  (ref) => DioRemoteMfaRepository(ref.watch(apiClientProvider)),
);
