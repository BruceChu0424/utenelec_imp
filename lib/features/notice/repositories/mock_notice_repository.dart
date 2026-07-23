// 通知 Mock 仓库

import 'dart:async';

import '../models/notice.dart';

class MockNoticeRepository {
  List<Notice>? _data;

  Future<T> _delay<T>(T Function() cb) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return cb();
  }

  List<Notice> _ensureData() {
    if (_data != null) return _data!;
    _data = _seed();
    return _data!;
  }

  Future<List<Notice>> list({bool? onlyUnread}) async {
    return _delay(() {
      var result = [..._ensureData()];
      if (onlyUnread == true) {
        result = result.where((n) => !n.isRead).toList();
      }
      // 置顶优先
      result.sort((a, b) {
        if (a.topPriority != b.topPriority) {
          return a.topPriority ? -1 : 1;
        }
        return b.publishedAt.compareTo(a.publishedAt);
      });
      return result;
    });
  }

  Future<Notice?> getById(String id) async {
    return _delay(() => _ensureData().firstWhere((n) => n.id == id));
  }

  Future<Notice> markRead(String id) async {
    return _delay(() {
      final list = _ensureData();
      final idx = list.indexWhere((n) => n.id == id);
      if (idx < 0) throw Exception('通知不存在');
      final updated = list[idx].copyWith(
        isRead: true,
        readAt: list[idx].readAt ?? DateTime.now(),
      );
      list[idx] = updated;
      return updated;
    });
  }

  /// 全部标记已读
  Future<void> markAllRead() async {
    return _delay(() {
      final list = _ensureData();
      for (var i = 0; i < list.length; i++) {
        if (!list[i].isRead) {
          list[i] = list[i].copyWith(
            isRead: true,
            readAt: list[i].readAt ?? DateTime.now(),
          );
        }
      }
    });
  }

  /// 未读数
  Future<int> unreadCount() async {
    return _delay(() => _ensureData().where((n) => !n.isRead).length);
  }

  List<Notice> _seed() {
    final now = DateTime.now();
    return [
      Notice(
        id: 'notice-001',
        title: '关于 7 月员工生日会的通知',
        content:
            '亲爱的同事们：\n\n为感谢大家的辛勤付出，公司定于 7 月 25 日（周五）下午 15:00 在多功能厅举办员工生日会。本月过生日的同事请准时参加，欢迎大家一同庆祝。\n\n活动安排：\n- 15:00 - 15:30 切蛋糕、合影\n- 15:30 - 16:30 团队小游戏\n- 16:30 - 17:00 茶歇交流\n\n如有疑问，请联系人事部 王经理。',
        type: NoticeType.benefit,
        publisher: '人事部',
        publishedAt: now.subtract(const Duration(hours: 2)),
        isRead: false,
      ),
      Notice(
        id: 'notice-002',
        title: '【紧急】本周六全厂设备检修通知',
        content:
            '各位同事：\n\n为保障设备稳定运行，公司决定于本周六（7 月 26 日）全天进行设备检修。\n\n检修期间：\n1. 生产线全部停产\n2. 楼栋空调将分时段关闭\n3. 食堂正常供应\n\n请各车间负责人提前安排好生产计划，停机前做好设备清理和物料归位。检修完成后会另行通知。\n\n如有紧急情况，请联系设备部 李工。',
        type: NoticeType.urgent,
        publisher: '生产部',
        publishedAt: now.subtract(const Duration(hours: 8)),
        isRead: false,
        topPriority: true,
      ),
      Notice(
        id: 'notice-003',
        title: '关于调整差旅报销标准的通知（2026 版）',
        content:
            '为规范差旅费用管理，结合公司实际情况，现将差旅报销标准调整如下，自 2026 年 8 月 1 日起执行：\n\n一、住宿标准\n- 一线城市（北上广深）：800 元/晚\n- 省会城市：600 元/晚\n- 其他城市：400 元/晚\n\n二、交通标准\n- 高铁：二等座\n- 飞机：经济舱（管理层以上可坐商务舱）\n- 市内交通：实报实销（含发票）\n\n三、餐饮补贴\n- 出差期间：100 元/天（无需发票）\n\n超出标准的费用需提前申请特批，否则不予报销。\n\n详见附件《2026 差旅管理办法》。',
        type: NoticeType.policy,
        publisher: '财务部',
        publishedAt: now.subtract(const Duration(days: 2)),
        isRead: true,
        attachments: const ['2026差旅管理办法.pdf'],
      ),
      Notice(
        id: 'notice-004',
        title: '系统升级公告：新版工资条查询功能上线',
        content:
            '各位同事：\n\n综合管理平台已完成系统升级，工资条查询功能全新改版：\n\n✓ 支持最近 12 个月工资条随时查询\n✓ 支持明细分类展示（应发/扣除）\n✓ 支持工资条下载（PDF 格式）\n✓ 工资条发布后将第一时间通知\n\n请通过"工作台 → 工资条"入口查看。\n\n如有问题，请提交建议或联系 IT 部。',
        type: NoticeType.system,
        publisher: 'IT 部',
        publishedAt: now.subtract(const Duration(days: 3)),
        isRead: true,
      ),
      Notice(
        id: 'notice-005',
        title: '2026 年中总结大会邀请',
        content:
            '各位同事：\n\n公司定于 7 月 30 日（周三）下午 14:00 在大礼堂召开 2026 年中总结大会。\n\n议程：\n- 上半年经营总结\n- 下半年战略规划\n- 优秀员工表彰\n- 团队合影\n\n请准时参加，着正装。',
        type: NoticeType.announcement,
        publisher: '总经理办公室',
        publishedAt: now.subtract(const Duration(days: 5)),
        isRead: true,
        attachments: const ['会议议程.docx', '参会名单.xlsx'],
      ),
      Notice(
        id: 'notice-006',
        title: '高温补贴发放通知',
        content:
            '根据国家相关规定，结合公司实际情况，6-9 月将向车间一线员工发放高温补贴，标准为 300 元/月，将随工资一同发放。\n\n具体发放名单由人事部核实车间考勤后报财务部执行。',
        type: NoticeType.benefit,
        publisher: '人事部',
        publishedAt: now.subtract(const Duration(days: 10)),
        isRead: true,
      ),
    ];
  }
}
