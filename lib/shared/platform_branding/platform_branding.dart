import '../../core/constants/app_info.dart';

/// Public company presentation. This does not change legal document ownership,
/// permissions, trusted server endpoints, or per-user appearance preferences.
class PlatformBranding {
  const PlatformBranding({
    this.version = 0,
    this.companyName = '中山市优腾电器有限公司',
    this.companyAliases = '',
    this.platformName = '优腾综合管理平台',
    this.tagline = '德国工匠 · 质造开关',
    this.primaryColor = '#0F766E',
    this.secondaryColor = '#2DD4BF',
    this.loginNotice = '',
    this.supportPhone = '',
    this.supportEmail = '',
    this.website = '',
    this.hasLogo = false,
    this.updatedAt,
    this.serverEndpoint,
  });

  static const defaults = PlatformBranding();

  final int version;
  final String companyName;
  final String companyAliases;
  final String platformName;

  /// Software identity is fixed; company metadata and historical platformName remain intact.
  String get appName => AppInfo.displayName;
  final String tagline;
  final String primaryColor;
  final String secondaryColor;
  final String loginNotice;
  final String supportPhone;
  final String supportEmail;
  final String website;
  final bool hasLogo;
  final String? updatedAt;

  /// In-memory source fence, never sent to or persisted by the server.
  final String? serverEndpoint;

  /// Bundled Uten artwork is appropriate only for the original company.
  bool get usesDefaultArtwork =>
      !hasLogo &&
      companyName == defaults.companyName &&
      platformName == defaults.platformName;

  bool get usesDefaultColors =>
      primaryColor.toUpperCase() == defaults.primaryColor &&
      secondaryColor.toUpperCase() == defaults.secondaryColor;

  String copyright(int year) => '© $year $companyName';

  factory PlatformBranding.fromJson(Map<String, dynamic> json) {
    String requiredText(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Invalid platform branding: $key');
      }
      return value.trim();
    }

    String color(String key) {
      final value = requiredText(key);
      if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(value)) {
        throw FormatException('Invalid platform branding color: $key');
      }
      return value.toUpperCase();
    }

    String optionalText(String key) {
      final value = json[key];
      if (value == null) return '';
      if (value is! String) {
        throw FormatException('Invalid platform branding: $key');
      }
      return value;
    }

    final version = json['version'];
    if (version is! num || version < 0 || version != version.toInt()) {
      throw const FormatException('Invalid platform branding: version');
    }
    if (json['hasLogo'] is! bool ||
        (json['updatedAt'] != null && json['updatedAt'] is! String)) {
      throw const FormatException('Invalid platform branding metadata');
    }
    return PlatformBranding(
      version: version.toInt(),
      companyName: requiredText('companyName'),
      companyAliases: optionalText('companyAliases'),
      platformName: requiredText('platformName'),
      tagline: optionalText('tagline'),
      primaryColor: color('primaryColor'),
      secondaryColor: color('secondaryColor'),
      loginNotice: optionalText('loginNotice'),
      supportPhone: optionalText('supportPhone'),
      supportEmail: optionalText('supportEmail'),
      website: optionalText('website'),
      hasLogo: json['hasLogo'] as bool,
      updatedAt: json['updatedAt'] as String?,
    );
  }

  Map<String, dynamic> toUpdateJson() => {
    'companyName': companyName,
    'companyAliases': companyAliases,
    'platformName': platformName,
    'tagline': tagline,
    'primaryColor': primaryColor,
    'secondaryColor': secondaryColor,
    'loginNotice': loginNotice,
    'supportPhone': supportPhone,
    'supportEmail': supportEmail,
    'website': website,
  };

  PlatformBranding forServer(String endpoint) => PlatformBranding(
    version: version,
    companyName: companyName,
    companyAliases: companyAliases,
    platformName: platformName,
    tagline: tagline,
    primaryColor: primaryColor,
    secondaryColor: secondaryColor,
    loginNotice: loginNotice,
    supportPhone: supportPhone,
    supportEmail: supportEmail,
    website: website,
    hasLogo: hasLogo,
    updatedAt: updatedAt,
    serverEndpoint: endpoint,
  );
}
