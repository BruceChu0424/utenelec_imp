// server_selection 单测：本地/云端自动选择决策表 + 模式/云端地址读写。
// 用真实 SharedPreferences（mock 后端）验证持久化；effectiveServerUrl 是纯函数，覆盖全部模式组合。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uten_imp/core/network/server_selection.dart';

const _local = 'http://10.0.0.1:8080/api';
const _cloud = 'https://cloud.example.com/api';

void main() {
  group('effectiveServerUrl 决策表', () {
    test('local 模式：恒用本地（忽略可达性与云端）', () {
      expect(
        effectiveServerUrl(
            mode: ServerMode.local, local: _local, cloud: _cloud, localReachable: false),
        _local,
      );
      expect(
        effectiveServerUrl(
            mode: ServerMode.local, local: _local, localReachable: true),
        _local,
      );
    });

    test('cloud 模式：用云端；未配回落本地', () {
      expect(
        effectiveServerUrl(
            mode: ServerMode.cloud, local: _local, cloud: _cloud, localReachable: true),
        _cloud,
      );
      expect(
        effectiveServerUrl(
            mode: ServerMode.cloud, local: _local, localReachable: false),
        _local,
      );
    });

    test('auto 模式：本地可达→本地；不可达→云端', () {
      // 在公司（本地可达）→ 本地
      expect(
        effectiveServerUrl(
            mode: ServerMode.auto, local: _local, cloud: _cloud, localReachable: true),
        _local,
      );
      // 在外（本地不可达）→ 云端
      expect(
        effectiveServerUrl(
            mode: ServerMode.auto, local: _local, cloud: _cloud, localReachable: false),
        _cloud,
      );
    });

    test('auto 模式：本地不可达且未配云端 → 回落本地（不会误用空云端）', () {
      expect(
        effectiveServerUrl(
            mode: ServerMode.auto, local: _local, localReachable: false),
        _local,
      );
    });
  });

  group('模式与云端地址读写（真实 SharedPreferences）', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('模式默认 auto；写入后读回', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(readServerMode(prefs), ServerMode.auto);

      await writeServerMode(prefs, ServerMode.cloud);
      expect(readServerMode(prefs), ServerMode.cloud);

      await writeServerMode(prefs, ServerMode.local);
      expect(readServerMode(prefs), ServerMode.local);
    });

    test('未知模式值回落 auto', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('uten.server_mode', 'garbage');
      expect(readServerMode(prefs), ServerMode.auto);
    });

    test('云端地址未设置→null；写入→读回；清空→null', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(readCloudUrl(prefs), isNull);

      await writeCloudUrl(prefs, 'https://cloud.example.com/api');
      expect(readCloudUrl(prefs), 'https://cloud.example.com/api');

      await writeCloudUrl(prefs, null);
      expect(readCloudUrl(prefs), isNull);
    });

    test('非法云端地址→null（不抛）', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('uten.server_url_override', 'not-a-url');
      expect(readCloudUrl(prefs), isNull);
    });

    test('resolveCloudUrl 合法返回解析值，非法抛 StateError', () {
      expect(resolveCloudUrl('https://cloud.example.com/api'),
          'https://cloud.example.com/api');
      expect(() => resolveCloudUrl('not-a-url'), throwsA(isA<StateError>()));
    });
  });
}
