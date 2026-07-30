import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/formatters/china_number_format.dart';
import 'package:uten_imp/core/input/china_input_formatters.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/security/input_validators.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/core/utils/id_card_utils.dart';
import 'package:uten_imp/features/report/shared/report_cell.dart';
import 'package:uten_imp/features/report/shared/report_column.dart';
import 'package:uten_imp/features/visitor/models/visitor_application.dart';
import 'package:uten_imp/shared/providers/locale_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('中国大陆 locale', () {
    test('首次启动固定 zh_CN，不依赖设备英文语言', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      expect(container.read(localeProvider), chinaLocale);
      expect(container.read(localeProvider).toLanguageTag(), 'zh-CN');
      expect(supportedLocales, contains(chinaLocale));
    });

    test('兼容历史语言偏好并保存完整区域', () async {
      SharedPreferences.setMockInitialValues({'locale': 'en'});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      expect(container.read(localeProvider), englishLocale);
      await container.read(localeProvider.notifier).set(chinaLocale);
      expect(prefs.getString('locale'), 'zh_CN');
    });

    testWidgets('Material 与 Cupertino 都加载 zh_CN 本地化', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: chinaLocale,
          supportedLocales: supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) => Column(
              children: [
                Text(Localizations.localeOf(context).toLanguageTag()),
                Text(MaterialLocalizations.of(context).okButtonLabel),
                Text(CupertinoLocalizations.of(context).todayLabel),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('zh-CN'), findsOneWidget);
      expect(find.text('确定'), findsOneWidget);
      expect(find.text('今天'), findsOneWidget);
    });
  });

  group('中国业务时间', () {
    test('UTC 跨日按 Asia/Shanghai 的 UTC+8 计算', () {
      final value = ChinaDateTime.now(
        utcNow: DateTime.utc(2026, 7, 30, 16, 30),
      );
      expect(ChinaDateTime.formatDateTime(value), '2026-07-31 00:30');
      expect(
        ChinaDateTime.formatDate(
          ChinaDateTime.today(utcNow: DateTime.utc(2026, 7, 30, 16, 30)),
        ),
        '2026-07-31',
      );
    });

    test('预约墙上时间转 UTC 不读取设备时区', () {
      final wall = ChinaDateTime.wallTime(
        year: 2026,
        month: 8,
        day: 1,
        hour: 9,
        minute: 15,
      );
      expect(
        ChinaDateTime.wallTimeToUtc(wall),
        DateTime.utc(2026, 8, 1, 1, 15),
      );
    });

    test('带偏移的 ISO 转中国时间，无偏移数据库时间保持原值', () {
      expect(
        ChinaDateTime.formatIsoInstant('2026-07-30T18:30:00Z'),
        '2026-07-31 02:30',
      );
      expect(
        ChinaDateTime.formatIsoInstant('2026-07-30T09:15:00+08:00'),
        '2026-07-30 09:15',
      );
      expect(
        ChinaDateTime.formatIsoInstant('2026-07-30T09:15:00'),
        '2026-07-30 09:15',
      );
      expect(ChinaDateTime.formatIsoInstant('2026-07-30'), '2026-07-30 00:00');
    });

    test('访客接口时间统一转换为中国墙上时间', () {
      final application = VisitorApplication.fromJson({
        'id': 'visitor-1',
        'visitorName': '访客',
        'visitPurpose': '商务',
        'status': 'pending',
        'plannedVisitAt': '2026-07-30T18:30:00Z',
        'appliedAt': '2026-07-30T09:15:00+08:00',
      });

      expect(
        ChinaDateTime.formatDateTime(application.plannedVisitAt),
        '2026-07-31 02:30',
      );
      expect(
        ChinaDateTime.formatDateTime(application.appliedAt),
        '2026-07-30 09:15',
      );
    });
  });

  group('中国输入与格式', () {
    test('居民身份证校验包含校验位、出生日期和顺序码', () {
      expect(IdCardUtils.isValid('11010519491231002X'), isTrue);
      expect(IdCardUtils.isValid('11010519491231002x'), isTrue);
      expect(
        IdCardUtils.isValid(_idWithChecksum('11010519490231002')),
        isFalse,
      );
      expect(
        IdCardUtils.isValid(_idWithChecksum('11010519491231000')),
        isFalse,
      );
    });

    test('手机号与大陆座机规则明确', () {
      expect(InputValidators.phone('13800138000'), isNull);
      expect(InputValidators.phone('12800138000'), isNotNull);
      expect(InputValidators.telephone('010-12345678'), isNull);
      expect(InputValidators.telephone('0571 12345678'), isNull);
      expect(InputValidators.telephone('021-12345678-123'), isNull);
      expect(InputValidators.telephone('12345'), isNotNull);
    });

    test('证件格式化不打断中文 IME composing', () {
      final formatter = ChinaInputFormatters.residentId.single;
      const composing = TextEditingValue(
        text: '张',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      expect(
        formatter.formatEditUpdate(TextEditingValue.empty, composing),
        composing,
      );

      const committed = TextEditingValue(
        text: '11010519491231002xabc',
        selection: TextSelection.collapsed(offset: 21),
      );
      expect(
        formatter.formatEditUpdate(TextEditingValue.empty, committed).text,
        '11010519491231002X',
      );
    });

    test('金额与报表数值使用中国千分位，小数和整数语义分开', () {
      expect(formatChinaNumber(1234567.8), '1,234,567.80');
      expect(formatCny(-1234.5), '-¥1,234.50');

      const money = ReportColumn(key: 'v', label: '金额', type: 'money');
      const integer = ReportColumn(key: 'v', label: '数量', type: 'int');
      expect(formatReportCell(money, const {'v': 12345.6}), '12,345.60');
      expect(formatReportCell(integer, const {'v': 12345}), '12,345');
    });
  });
}

String _idWithChecksum(String first17) {
  const weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
  const checks = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];
  var sum = 0;
  for (var i = 0; i < first17.length; i++) {
    sum += int.parse(first17[i]) * weights[i];
  }
  return '$first17${checks[sum % 11]}';
}
