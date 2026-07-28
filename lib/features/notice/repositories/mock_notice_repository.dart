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

  /// 发布新通知（人事广播类）。插入到列表最前，返回入库后的实体。
  Future<Notice> publish({
    required String title,
    required String content,
    required NoticeType type,
    required String publisher,
    bool topPriority = false,
    NoticePriority priority = NoticePriority.normal,
  }) async {
    return _delay(() {
      final list = _ensureData();
      final notice = Notice(
        id: 'notice-${DateTime.now().millisecondsSinceEpoch}',
        title: title,
        content: content,
        type: type,
        publisher: publisher,
        publishedAt: DateTime.now(),
        isRead: false,
        topPriority: topPriority,
        priority: priority,
      );
      list.insert(0, notice);
      return notice;
    });
  }

  int _incomingSeq = 0;

  /// 模拟「收到一条新工作通知」（接真后端后由推送/WebSocket 触发）。
  ///
  /// 轮换产生工作平台三类典型事件：任务下发 / 上游完成 / 审批结果，
  /// 覆盖 normal / important 两种重要度（urgent 由发布通道演示）。
  /// 插入仓储并返回新通知，调用方负责刷新列表 + 弹出到达提醒。
  Future<Notice> simulateIncoming() async {
    return _delay(() {
      final list = _ensureData();
      final seq = _incomingSeq++;
      final now = DateTime.now();
      final id = 'notice-in-${now.millisecondsSinceEpoch}';

      final notice = switch (seq % 3) {
        // 任务下发（重要 → 居中弹窗）
        0 => Notice(
            id: id,
            title: '新任务下发：7 月盘点差异复核',
            content:
                '仓储部下发盘点任务：\n\n7 月月度盘点存在 3 项差异（A 区原料仓 2 项、成品仓 1 项），请在 3 个工作日内完成复核并提交差异说明。\n\n任务编号：PD-2026-0718\n截止时间：${now.add(const Duration(days: 3)).month} 月 ${now.add(const Duration(days: 3)).day} 日 18:00\n\n请通过"工作台 → 库存 → 盘点"入口处理。',
            type: NoticeType.task,
            publisher: '仓储部',
            publishedAt: now,
            isRead: false,
            priority: NoticePriority.important,
          ),
        // 上游完成（一般 → 顶部弹条）
        1 => Notice(
            id: id,
            title: '上游完成：采购单 PO-2026-0205 已到货入库',
            content:
                '你关注的采购流程节点已更新：\n\n采购单 PO-2026-0205（包装材料一批）已由供应商送达，仓储部完成到货入库，质检流程已自动流转至质量部。\n\n入库数量：1,200 件\n入库时间：${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}\n\n该节点为你的下游任务的触发条件，可开始安排后续工作。',
            type: NoticeType.workflow,
            publisher: '采购部',
            publishedAt: now,
            isRead: false,
          ),
        // 审批结果（一般 → 顶部弹条）
        _ => Notice(
            id: id,
            title: '审批通过：你的请假申请已批准',
            content:
                '你提交的请假申请（事假 1 天）已由直属上级 张经理 审批通过。\n\n申请编号：QJ-2026-0092\n请假日期：${now.add(const Duration(days: 5)).month} 月 ${now.add(const Duration(days: 5)).day} 日\n\n考勤记录已自动更新。',
            type: NoticeType.approval,
            publisher: '张经理',
            publishedAt: now,
            isRead: false,
          ),
      };

      list.insert(0, notice);
      return notice;
    });
  }

  List<Notice> _seed() {
    final now = DateTime.now();
    return [
      Notice(
        id: 'notice-w01',
        title: '新任务下发：B 区产线 5S 整改',
        content:
            '生产部下发整改任务：\n\n本周巡检发现 B 区产线 3 处 5S 不达标项（物料堆放、通道标识、工具归位），请在本周五前完成整改并拍照上传。\n\n任务编号：ZG-2026-0715\n责任人：当班班长\n\n请通过"工作台 → 生产"入口反馈进度。',
        type: NoticeType.task,
        publisher: '生产部',
        publishedAt: now.subtract(const Duration(minutes: 40)),
        isRead: false,
        priority: NoticePriority.important,
      ),
      Notice(
        id: 'notice-w02',
        title: '上游完成：外协订单 WX-2026-0089 已回货',
        content:
            '你关注的外协流程节点已更新：\n\n外协订单 WX-2026-0089（五金件表面处理）已由外协厂完成并回货，当前处于 IQC 来料检验环节。\n\n回货数量：800 件\n\n检验通过后流转至你的入库任务，请提前安排。',
        type: NoticeType.workflow,
        publisher: '供应链部',
        publishedAt: now.subtract(const Duration(hours: 1)),
        isRead: false,
      ),
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
        priority: NoticePriority.urgent,
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
