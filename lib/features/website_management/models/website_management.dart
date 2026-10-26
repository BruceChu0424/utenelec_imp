import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';

const websiteAllowLoopbackHttp = bool.fromEnvironment(
  'UTEN_WEBSITE_ALLOW_LOOPBACK_HTTP',
);

/// Public-site and editor handoffs share one origin policy. Callers opt into
/// local HTTP explicitly; a real Release build cannot override HTTPS protection.
Uri websiteOriginUri(
  String configured, {
  required bool releaseMode,
  required bool allowLoopbackHttp,
}) {
  final uri = Uri.tryParse(configured);
  final localHttp =
      !kReleaseMode &&
      !releaseMode &&
      allowLoopbackHttp &&
      uri?.scheme == 'http' &&
      const {'127.0.0.1', 'localhost', '::1'}.contains(uri?.host);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      (uri.scheme != 'https' && !localHttp) ||
      uri.userInfo.isNotEmpty ||
      // Uri canonicalization can discard an empty user-info marker.
      configured.contains('@') ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw ApiException('WEBSITE_UNTRUSTED_TARGET', 'Website target rejected');
  }
  return uri;
}

class WebsiteManagementInfo {
  const WebsiteManagementInfo({
    required this.version,
    required this.displayName,
    required this.publicOrigin,
    required this.adminOrigin,
    required this.enabled,
    required this.configured,
    required this.tokenConfigured,
    this.canConfigure = false,
    this.allowedOrigins = const [],
    this.permissions = const {},
    this.lastCheckedAt,
    this.lastSyncAt,
    this.lastError,
    this.pendingInquiries,
    this.adminEntryPath = '/admin/imp-entry',
  });

  final int version;
  final String displayName, publicOrigin, adminOrigin, adminEntryPath;
  final bool enabled, configured, tokenConfigured, canConfigure;
  final List<String> allowedOrigins;
  final Set<String> permissions;
  final DateTime? lastCheckedAt, lastSyncAt;
  final String? lastError;
  final int? pendingInquiries;

  factory WebsiteManagementInfo.fromJson(Map<String, dynamic> j) =>
      WebsiteManagementInfo(
        version: (j['version'] as num?)?.toInt() ?? 0,
        displayName: j['displayName'] as String? ?? '',
        publicOrigin: j['publicOrigin'] as String? ?? '',
        adminOrigin: j['adminOrigin'] as String? ?? '',
        adminEntryPath: j['adminEntryPath'] as String? ?? '',
        enabled: j['enabled'] == true,
        configured: j['configured'] == true,
        tokenConfigured: j['tokenConfigured'] == true,
        canConfigure: j['canConfigure'] == true,
        allowedOrigins: (j['allowedOrigins'] as List? ?? [])
            .whereType<String>()
            .toList(),
        permissions: (j['permissions'] as List? ?? [])
            .whereType<String>()
            .toSet(),
        lastCheckedAt: DateTime.tryParse(j['lastCheckedAt'] as String? ?? ''),
        lastSyncAt: DateTime.tryParse(j['lastSyncAt'] as String? ?? ''),
        lastError: j['lastError'] as String?,
        pendingInquiries: (j['pendingInquiries'] as num?)?.toInt(),
      );
}

class WebsiteConnectionCheck {
  const WebsiteConnectionCheck({
    required this.checkedAt,
    required this.reachable,
    required this.ready,
    this.message,
    this.siteId,
    this.publishedRevision,
    this.pendingInquiries,
  });

  final DateTime checkedAt;
  final bool reachable, ready;
  final String? message, siteId, publishedRevision;
  final int? pendingInquiries;

  factory WebsiteConnectionCheck.fromJson(Map<String, dynamic> j) =>
      WebsiteConnectionCheck(
        checkedAt: DateTime.parse(j['checkedAt'] as String),
        reachable: j['reachable'] == true,
        ready: j['ready'] == true,
        message: j['message'] as String?,
        siteId: j['siteId'] as String?,
        publishedRevision: j['publishedRevision']?.toString(),
        pendingInquiries: (j['pendingInquiries'] as num?)?.toInt(),
      );
}

class WebsiteManagementSnapshot {
  const WebsiteManagementSnapshot(this.info, {this.check, this.checkError});
  final WebsiteManagementInfo info;
  final WebsiteConnectionCheck? check;
  final Object? checkError;
  bool get ready => info.enabled && info.configured && check?.ready == true;
}

class WebsiteEditorGrant {
  const WebsiteEditorGrant({
    required this.entryUrl,
    required this.code,
    required this.expiresAt,
  });
  final String entryUrl, code;
  final DateTime expiresAt;
  factory WebsiteEditorGrant.fromJson(Map<String, dynamic> j) =>
      WebsiteEditorGrant(
        entryUrl: j['entryUrl'] as String,
        code: j['code'] as String,
        expiresAt: DateTime.parse(j['expiresAt'] as String),
      );
}

/// The verifier exists only for this handoff. Never store or log it or the URL.
class WebsiteHandoffProof {
  WebsiteHandoffProof._(this.verifier);
  factory WebsiteHandoffProof.create() {
    final random = Random.secure();
    return WebsiteHandoffProof._(
      base64UrlEncode(
        List<int>.generate(32, (_) => random.nextInt(256)),
      ).replaceAll('=', ''),
    );
  }
  final String verifier;
  String get challenge => base64UrlEncode(
    sha256.convert(utf8.encode(verifier)).bytes,
  ).replaceAll('=', '');
}

/// Both the authenticated configuration and the fixed entry path must agree.
/// No employee token is passed to the browser; the short-lived code is one use.
Uri websiteEditorUri({
  required WebsiteManagementInfo info,
  required WebsiteEditorGrant grant,
  required WebsiteHandoffProof proof,
  required DateTime now,
  required bool releaseMode,
  required bool allowLoopbackHttp,
}) {
  final origin = websiteOriginUri(
    info.adminOrigin,
    releaseMode: releaseMode,
    allowLoopbackHttp: allowLoopbackHttp,
  );
  final public = websiteOriginUri(
    info.publicOrigin,
    releaseMode: releaseMode,
    allowLoopbackHttp: allowLoopbackHttp,
  );
  final entry = Uri.tryParse(grant.entryUrl);
  if (origin.origin != public.origin ||
      info.adminEntryPath != '/admin/imp-entry' ||
      entry == null ||
      entry.scheme != origin.scheme ||
      !entry.hasAuthority ||
      entry.host.isEmpty ||
      entry.userInfo.isNotEmpty ||
      grant.entryUrl.contains('@') ||
      entry.origin != origin.origin ||
      entry.path != '/admin/imp-entry' ||
      entry.hasQuery ||
      entry.hasFragment ||
      !RegExp(r'^[A-Za-z0-9_-]{20,256}$').hasMatch(grant.code) ||
      !grant.expiresAt.isAfter(now) ||
      grant.expiresAt.difference(now) > const Duration(minutes: 2)) {
    throw ApiException(
      'WEBSITE_UNTRUSTED_TARGET',
      'Website editor target rejected',
    );
  }
  return entry.replace(
    fragment: Uri(
      queryParameters: {'code': grant.code, 'verifier': proof.verifier},
    ).query,
  );
}
