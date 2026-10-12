import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'platform_branding.dart';

/// Cache identity is independent of application/release versions. A web /api
/// endpoint also binds its origin; this key never selects a network host.
String platformBrandingCacheScope(
  String endpoint, {
  bool web = kIsWeb,
  Uri? browserUri,
}) => web && endpoint.startsWith('/')
    ? '${(browserUri ?? Uri.base).origin}$endpoint'
    : endpoint;

/// Only public presentation data. Never authority for connectivity, access,
/// server selection or administrative editing. A cold start may display the
/// last confirmed brand while the authoritative read still fails/loading.
class PlatformBrandingCache {
  PlatformBrandingCache(this.preferences);

  // Keep this stable across client upgrades. Schema changes require a cache
  // migration/backward reader; APP_VERSION must never become part of the key.
  static const preferenceKey = 'uten.platform_branding.cache';
  static const maxEndpoints = 2;
  static const maxLogoBytes = 524288;
  static const _maxEntryChars = 750000;
  static const _maxCacheChars = maxEndpoints * _maxEntryChars + 100;
  static const _schema = 1;
  final SharedPreferences preferences;
  Future<void> _writeTail = Future.value();
  final _pendingLogos = <String, ({int version, Uint8List bytes})>{};

  PlatformBranding? readBrand(String endpoint) {
    final entry = _entries()[platformBrandingCacheScope(endpoint)];
    if (entry == null) return null;
    return _decodeBrand(entry['branding'])?.forServer(endpoint);
  }

  Uint8List? readLogo(String endpoint, int version) {
    final entry = _entries()[platformBrandingCacheScope(endpoint)];
    return entry == null ? null : _decodeLogo(entry, version);
  }

  /// Only successful, still-current server reads may reach this write path.
  /// A fresh authoritative database restore may legitimately lower version.
  Future<void> saveBrand(
    String endpoint,
    PlatformBranding branding, {
    required bool Function() isCurrent,
  }) => _serialize(() async {
    if (!isCurrent() || branding.serverEndpoint != endpoint) return;
    final payload = <String, dynamic>{
      ...branding.toUpdateJson(),
      'version': branding.version,
      'hasLogo': branding.hasLogo,
      'updatedAt': branding.updatedAt,
    };
    if (_decodeBrand(payload) == null) return;
    final scope = platformBrandingCacheScope(endpoint);
    final entries = _entries();
    final old = entries.remove(scope);
    final oldBrand = old == null ? null : _decodeBrand(old['branding']);
    final pending = _pendingLogos.remove(scope);
    final next = <String, dynamic>{'endpoint': scope, 'branding': payload};
    if (branding.hasLogo && pending?.version == branding.version) {
      next.addAll({
        'logoVersion': branding.version,
        'logoPng': base64Encode(pending!.bytes),
        'logoSha256': sha256.convert(pending.bytes).toString(),
      });
    } else if (branding.hasLogo &&
        old != null &&
        mapEquals(oldBrand?.toUpdateJson(), branding.toUpdateJson()) &&
        _decodeLogo(old, branding.version) != null) {
      next.addAll({
        'logoVersion': branding.version,
        'logoPng': old['logoPng'],
        'logoSha256': old['logoSha256'],
      });
    }
    entries[scope] = next;
    while (entries.length > maxEndpoints) {
      entries.remove(entries.keys.first);
    }
    if (isCurrent()) await _persist(entries);
  });

  Future<void> saveLogo(
    String endpoint,
    int version,
    Uint8List bytes, {
    required bool Function() isCurrent,
  }) => _serialize(() async {
    if (!isCurrent() || !isSafePlatformLogo(bytes)) return;
    final scope = platformBrandingCacheScope(endpoint);
    final entries = _entries();
    final entry = entries[scope];
    final brand = entry == null ? null : _decodeBrand(entry['branding']);
    if (brand?.version == version && brand?.hasLogo == false) return;
    if (entry == null || brand?.version != version || brand?.hasLogo != true) {
      // An admin preview can fetch a newly saved logo before the public
      // metadata refresh finishes. Keep bounded memory only until a matching
      // authoritative metadata read arrives; never persist an unbound bitmap.
      _pendingLogos.remove(scope);
      _pendingLogos[scope] = (version: version, bytes: bytes);
      while (_pendingLogos.length > maxEndpoints) {
        _pendingLogos.remove(_pendingLogos.keys.first);
      }
      return;
    }
    entries[scope] = {
      ...entry,
      'logoVersion': version,
      'logoPng': base64Encode(bytes),
      'logoSha256': sha256.convert(bytes).toString(),
    };
    if (isCurrent()) await _persist(entries);
  });

  Future<void> _serialize(Future<void> Function() write) {
    final next = _writeTail.then((_) => write());
    // Cache persistence failure must not poison subsequent writes or turn a
    // successful server read into failure. Callers still receive this error.
    _writeTail = next.catchError((Object _) {});
    return next;
  }

  Map<String, Map<String, dynamic>> _entries() {
    try {
      final raw = preferences.getString(preferenceKey);
      if (raw == null || raw.length > _maxCacheChars) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['schema'] != _schema) return {};
      final entries = decoded['entries'];
      if (entries is! List || entries.length > maxEndpoints) return {};
      final result = <String, Map<String, dynamic>>{};
      for (final entry in entries) {
        if (entry is! Map<String, dynamic>) continue;
        if (jsonEncode(entry).length > _maxEntryChars) continue;
        final endpoint = entry['endpoint'];
        if (endpoint is! String ||
            endpoint.isEmpty ||
            endpoint.length > 2048 ||
            RegExp(r'[\x00-\x1F\x7F]').hasMatch(endpoint) ||
            _decodeBrand(entry['branding']) == null) {
          continue;
        }
        result[endpoint] = entry;
      }
      return result;
    } catch (_) {
      // Ignore only this optional cache. Never remove other application prefs.
      return {};
    }
  }

  Future<void> _persist(Map<String, Map<String, dynamic>> entries) async {
    final encoded = jsonEncode({
      'schema': _schema,
      'entries': entries.values.toList(),
    });
    if (encoded.length > _maxCacheChars) return;
    if (preferences.getString(preferenceKey) != encoded) {
      await preferences.setString(preferenceKey, encoded);
    }
  }

  static PlatformBranding? _decodeBrand(Object? value) {
    try {
      if (value is! Map<String, dynamic>) return null;
      final brand = PlatformBranding.fromJson(value);
      if (brand.version > 0x7fffffff) return null;
      final fields = <String, int>{
        'companyName': 120,
        'companyAliases': 500,
        'platformName': 80,
        'tagline': 160,
        'loginNotice': 500,
        'supportPhone': 50,
        'supportEmail': 120,
        'website': 200,
      };
      for (final field in fields.entries) {
        final text = value[field.key] ?? '';
        if (text is! String || text.length > field.value) return null;
        final controls = switch (field.key) {
          'companyAliases' => RegExp(r'[\x00-\x09\x0B-\x1F\x7F-\x9F]'),
          'loginNotice' => RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]'),
          _ => RegExp(r'[\x00-\x1F\x7F-\x9F]'),
        };
        if (controls.hasMatch(text)) return null;
      }
      final aliases = brand.companyAliases
          .split('\n')
          .map((alias) => alias.trim())
          .where((alias) => alias.isNotEmpty)
          .toList();
      if (aliases.length > 16 ||
          aliases.any((alias) => alias.length < 2 || alias.length > 120)) {
        return null;
      }
      if (brand.updatedAt != null &&
          DateTime.tryParse(brand.updatedAt!) == null) {
        return null;
      }
      if (brand.supportEmail.isNotEmpty &&
          !RegExp(
            r'^[^\x09-\x0D\x20@]+@[^\x09-\x0D\x20@]+\.[^\x09-\x0D\x20@]+$',
          ).hasMatch(brand.supportEmail)) {
        return null;
      }
      if (brand.website.isNotEmpty) {
        final website = Uri.tryParse(brand.website);
        if (website == null ||
            website.scheme.toLowerCase() != 'https' ||
            website.host.isEmpty ||
            website.userInfo.isNotEmpty) {
          return null;
        }
      }
      return brand;
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _decodeLogo(Map<String, dynamic> entry, int version) {
    try {
      final brand = _decodeBrand(entry['branding']);
      if (brand?.version != version ||
          brand?.hasLogo != true ||
          entry['logoVersion'] != version) {
        return null;
      }
      final encoded = entry['logoPng'];
      final checksum = entry['logoSha256'];
      if (encoded is! String ||
          encoded.length > ((maxLogoBytes + 2) ~/ 3) * 4 ||
          checksum is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
        return null;
      }
      final bytes = base64Decode(encoded);
      return isSafePlatformLogo(bytes) &&
              sha256.convert(bytes).toString() == checksum
          ? bytes
          : null;
    } catch (_) {
      return null;
    }
  }
}

/// The server sanitizes logos to PNG; cache reads still validate byte and
/// bitmap bounds before allowing an untrusted local value into an image codec.
bool isSafePlatformLogo(Uint8List bytes) {
  if (bytes.length < 33 || bytes.length > PlatformBrandingCache.maxLogoBytes) {
    return false;
  }
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  final header = ByteData.sublistView(bytes);
  if (header.getUint32(8) != 13 || header.getUint32(12) != 0x49484452) {
    return false;
  }
  final width = header.getUint32(16);
  final height = header.getUint32(20);
  if (width <= 0 ||
      height <= 0 ||
      width > 2048 ||
      height > 2048 ||
      width * height > 4194304) {
    return false;
  }
  var offset = 8;
  var hasImageData = false;
  while (offset + 12 <= bytes.length) {
    final length = header.getUint32(offset);
    final type = header.getUint32(offset + 4);
    final next = offset + 12 + length;
    if (next > bytes.length) return false;
    if (type == 0x49444154 && length > 0) hasImageData = true; // IDAT
    if (type == 0x49454e44) {
      return length == 0 && next == bytes.length && hasImageData; // IEND
    }
    offset = next;
  }
  return false;
}
