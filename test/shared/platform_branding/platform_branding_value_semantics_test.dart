// 品牌值语义发布(2026-11-10 性能根治 C 项)：
// 60s 品牌轮询每周期产生新实例——同载荷时不得向下游重发布"变了"的对象，
// 否则整个应用重跑主题构造并重放 200ms 主题过渡(实测 14 帧全应用重建)。
// 这里钉死三层：PlatformBranding 值相等、主题构建器值键缓存(同值→同实例)、
// 快照 Provider 跨两个轮询周期等载荷零再通知(下游不重建→不重读平台 values、
// 不重启列宽测量)。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _payload = <String, dynamic>{
  'version': 7,
  'companyName': '测试公司',
  'platformName': '测试平台',
  'tagline': '口号',
  'primaryColor': '#115E59',
  'secondaryColor': '#5EEAD4',
  'hasLogo': true,
  'updatedAt': '2026-11-10T00:00:00Z',
};

class _CannedAdapter implements HttpClientAdapter {
  Map<String, dynamic> payload;
  _CannedAdapter(this.payload);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(payload),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同载荷两份解析结果值相等; 换内容/换端点不相等', () {
    final a = PlatformBranding.fromJson(_payload);
    final b = PlatformBranding.fromJson(_payload);
    expect(a, isNot(same(b)));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    final changed = PlatformBranding.fromJson({
      ..._payload,
      'companyName': '另一家公司',
    });
    expect(a, isNot(equals(changed)), reason: '库恢复复用版本号换内容必须不相等');
    expect(a.forServer('https://a.test'), isNot(equals(a.forServer('https://b.test'))),
        reason: '来源栅栏参与值身份');
  });

  test('主题构建器值键缓存: 同值品牌(新实例)→同一 ThemeData 实例', () {
    final a = PlatformBranding.fromJson(_payload);
    final b = PlatformBranding.fromJson(_payload);
    final light1 = buildLightTheme(branding: a);
    final light2 = buildLightTheme(branding: b);
    expect(identical(light1, light2), isTrue,
        reason: '无关根重建拿到同一实例,MaterialApp 才不会重放主题过渡');
    final dark1 = buildDarkTheme(branding: a);
    final dark2 = buildDarkTheme(branding: b);
    expect(identical(dark1, dark2), isTrue);
    final changed = PlatformBranding.fromJson({
      ..._payload,
      'primaryColor': '#B91C1C',
    });
    expect(identical(light1, buildLightTheme(branding: changed)), isFalse,
        reason: '品牌真变化必须重建主题');
    expect(identical(light1, buildLightTheme(branding: a)), isTrue,
        reason: '换回原值恢复缓存命中');
  });

  test('主题值键缓存按平台隔离: 密度与转场平台相关, 换平台不得复用他平台实例', () {
    final branding = PlatformBranding.fromJson(_payload);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final windowsLight = buildLightTheme(branding: branding);
    final windowsDark = buildDarkTheme(branding: branding);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final androidLight = buildLightTheme(branding: branding);
    final androidDark = buildDarkTheme(branding: branding);
    expect(identical(windowsLight, androidLight), isFalse,
        reason: '同品牌值在不同目标平台必须各建各的(adaptivePlatformDensity/转场平台相关)');
    expect(identical(windowsDark, androidDark), isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(identical(buildLightTheme(branding: branding), windowsLight), isTrue,
        reason: '回到原平台恢复缓存命中');
    expect(identical(buildDarkTheme(branding: branding), windowsDark), isTrue);
  });

  test('跨两个轮询周期等载荷: 快照零再通知(下游不重建)', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dio = Dio(BaseOptions(baseUrl: 'https://brand.test'))
      ..httpClientAdapter = _CannedAdapter(_payload);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiBaseUrlProvider.overrideWith((ref) => 'https://brand.test'),
        platformBrandingDioProvider.overrideWithValue(dio),
      ],
    );
    addTearDown(container.dispose);
    var notified = 0;
    PlatformBranding? latest;
    container.listen(platformBrandingSnapshotProvider, (previous, next) {
      notified++;
      latest = next;
    }, fireImmediately: true);
    // 轮询周期 1(初始拉取): defaults → 真实品牌是一次真变化
    //(fireImmediately 的 defaults 计一次,真实发布计一次)。
    await container.read(platformBrandingProvider.future);
    await container.pump();
    expect(notified, 2, reason: '初始 defaults→真实品牌恰一次真实通知');
    expect(latest!.version, 7);
    final lightFirst = buildLightTheme(branding: latest);
    // 轮询周期 2、3(60s 定时器做的事就是 invalidateSelf)。
    container.invalidate(platformBrandingProvider);
    await container.read(platformBrandingProvider.future);
    await container.pump();
    container.invalidate(platformBrandingProvider);
    await container.read(platformBrandingProvider.future);
    await container.pump();
    expect(notified, 2,
        reason: '等载荷轮询周期不得向下游重发布——否则全应用主题重放、'
            '表格重读平台 values 并重启列宽测量');
    expect(buildLightTheme(branding: latest), same(lightFirst));
  });
}
