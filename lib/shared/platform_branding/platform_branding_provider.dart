import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/connection_recovery.dart';
import '../../core/network/server_config.dart';
import '../providers/app_visibility_provider.dart';
import '../providers/shared_providers.dart';
import 'platform_branding.dart';
import 'platform_branding_cache.dart';

final platformBrandingCacheProvider = Provider<PlatformBrandingCache>((ref) {
  return PlatformBrandingCache(ref.watch(sharedPreferencesProvider));
});

/// A separate anonymous client: branding is available on the login page and
/// must never carry staff credentials or follow redirects to another host.
final platformBrandingDioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: ref.watch(apiBaseUrlProvider),
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      sendTimeout: const Duration(seconds: 5),
      followRedirects: false,
    ),
  );
  ref.onDispose(() => dio.close(force: true));
  return dio;
});

/// Exactly one public read/refresh loop per current endpoint. Riverpod
/// disposes the old request when the effective server changes; consumers must
/// use AsyncData only, never a previous endpoint's retained loading value.
final FutureProvider<PlatformBranding>
platformBrandingProvider = FutureProvider<PlatformBranding>((ref) async {
  final endpoint = ref.watch(apiBaseUrlProvider);
  final dio = ref.watch(platformBrandingDioProvider);
  final cache = ref.watch(platformBrandingCacheProvider);
  ref.watch(connectionRecoveryProvider.select((state) => state.recoveryEpoch));
  final cancel = CancelToken();
  var alive = true;
  ref.onDispose(() => alive = false);
  ref.onDispose(() => cancel.cancel());
  ref.listen<bool>(appVisibilityProvider, (previous, visible) {
    if (previous == false && visible) ref.invalidateSelf();
  });
  final timer = Timer.periodic(const Duration(seconds: 60), (_) {
    if (ref.read(appVisibilityProvider)) ref.invalidateSelf();
  });
  ref.onDispose(timer.cancel);
  final response = await dio.get<dynamic>(
    '/platform/branding',
    cancelToken: cancel,
  );
  final data = response.data;
  if (data is! Map<String, dynamic>) {
    throw const FormatException('Invalid platform branding response');
  }
  final branding = PlatformBranding.fromJson(data).forServer(endpoint);
  bool current() => alive && ref.read(apiBaseUrlProvider) == endpoint;
  final previous = cache.readBrand(endpoint);
  try {
    await cache.saveBrand(endpoint, branding, isCurrent: current);
  } catch (_) {
    // Optional cache failure cannot negate a successfully verified API read.
  }
  if (current() &&
      previous?.version == branding.version &&
      (!mapEquals(previous?.toUpdateJson(), branding.toUpdateJson()) ||
          previous?.hasLogo != branding.hasLogo)) {
    // A restored/replaced database can reuse a version. Do not combine its
    // confirmed new company metadata with an old in-memory logo for that key.
    ref.invalidate(platformBrandingLogoProvider(branding.version));
  }
  return branding;
});

final platformBrandingSnapshotProvider = Provider<PlatformBranding>((ref) {
  final value = ref.watch(platformBrandingProvider);
  final endpoint = ref.watch(apiBaseUrlProvider);
  final brand = value.value;
  // Keep the last read through temporary errors on the same server, but never
  // display another endpoint's retained AsyncLoading/AsyncError value.
  if (brand != null &&
      (brand.serverEndpoint == null || brand.serverEndpoint == endpoint)) {
    return brand;
  }
  return ref.watch(platformBrandingCacheProvider).readBrand(endpoint) ??
      PlatformBranding.defaults;
});

final platformBrandingLogoProvider = StreamProvider.autoDispose
    .family<Uint8List?, int>((ref, version) async* {
      final endpoint = ref.watch(apiBaseUrlProvider);
      final dio = ref.watch(platformBrandingDioProvider);
      final cache = ref.watch(platformBrandingCacheProvider);
      final cancel = CancelToken();
      var alive = true;
      ref.onDispose(() => alive = false);
      ref.onDispose(() => cancel.cancel());
      bool current() => alive && ref.read(apiBaseUrlProvider) == endpoint;
      final cached = cache.readLogo(endpoint, version);
      if (cached != null) yield cached;
      try {
        final response = await dio.get<List<int>>(
          '/platform/branding/logo',
          queryParameters: {'v': version},
          options: Options(
            responseType: ResponseType.bytes,
            validateStatus: (status) => status == 200 || status == 404,
          ),
          cancelToken: cancel,
        );
        if (response.statusCode == 404) {
          if (current()) {
            if (cached != null) {
              // A missing route or stale version also returns 404 during a
              // rolling upgrade/restore. Only fresh hasLogo=false metadata
              // may remove the previously confirmed artwork.
              ref.invalidate(platformBrandingProvider);
            } else {
              yield null;
            }
          }
          return;
        }
        final bytes = response.data;
        final logo = bytes == null ? null : Uint8List.fromList(bytes);
        if (logo == null || !isSafePlatformLogo(logo)) {
          throw const FormatException('Invalid platform logo');
        }
        try {
          await cache.saveLogo(endpoint, version, logo, isCurrent: current);
        } catch (_) {}
        if (current()) yield logo;
      } catch (_) {
        if (!current() || cached != null) return;
        rethrow;
      }
    });
