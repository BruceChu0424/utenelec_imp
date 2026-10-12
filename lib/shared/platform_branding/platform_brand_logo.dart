import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/assets.dart';
import '../../core/network/server_config.dart';
import 'platform_branding.dart';
import 'platform_branding_provider.dart';

/// Uses only bytes from the current trusted API endpoint. Uploaded artwork
/// never introduces an external image URL or authenticated image request.
class PlatformBrandLogo extends ConsumerWidget {
  const PlatformBrandLogo({
    super.key,
    this.branding,
    this.width = 240,
    this.height = 44,
    this.compact = false,
  });

  final PlatformBranding? branding;
  final double width;
  final double height;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlatformBranding requestedBrand =
        branding ??
        ref.watch<PlatformBranding>(platformBrandingSnapshotProvider);
    final currentEndpoint = ref.watch(apiBaseUrlProvider);
    final currentSource =
        requestedBrand.serverEndpoint == null ||
        requestedBrand.serverEndpoint == currentEndpoint;
    final brand = currentSource ? requestedBrand : PlatformBranding.defaults;
    final logo = brand.hasLogo && currentSource
        ? ref.watch(platformBrandingLogoProvider(brand.version))
        : null;
    final bytes = logo is AsyncData ? logo?.value : null;
    final fallback = _fallback(context, brand);
    return SizedBox(
      width: width,
      height: height,
      child: bytes == null
          ? fallback
          : Image.memory(
              bytes,
              fit: BoxFit.contain,
              semanticLabel: brand.companyName,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }

  Widget _fallback(BuildContext context, PlatformBranding brand) {
    if (brand.usesDefaultArtwork) {
      return Image.asset(
        compact ? UtenAssets.logoIp : UtenAssets.logoName,
        fit: BoxFit.contain,
        semanticLabel: brand.companyName,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: brand.companyName,
      child: compact
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text(
                  brand.companyName.trim().isEmpty
                      ? '企'
                      : brand.companyName.trim().characters.first,
                  style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontSize: height * 0.48,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            )
          : Center(
              child: Text(
                brand.platformName.trim().isEmpty ? '企业平台' : brand.platformName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
    );
  }
}
