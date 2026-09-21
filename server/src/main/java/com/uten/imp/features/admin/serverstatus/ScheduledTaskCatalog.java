package com.uten.imp.features.admin.serverstatus;

import java.util.Map;
import java.util.Optional;
import java.util.Set;

/**
 * 后台自动任务的人话名称与用途 (2026-09-20)。
 *
 * <p>用户看到「定时任务 InventoryValueWorkScheduler.scheduled 接近预警值」的第一反应是
 * 「我没有设置过定时任务啊」: 这些任务全部是平台内置、随服务自动运行的, 类名.方法名只对
 * 开发者有意义。状态页与告警通知一律改用这里的名称和用途说明; 程序标识 (与
 * {@link ScheduledTaskRunRegistry} 的命名一致: 声明类简名.方法名) 只留在 key 里做身份。</p>
 *
 * <p>{@code ScheduledTaskCatalogTest} 与源码双向对账: 每个 {@code @Scheduled} 方法都必须在此
 * 登记, 登记项也不得指向已不存在的方法。新增定时任务时在这里补一行即可。</p>
 */
public final class ScheduledTaskCatalog {

    /** 人话名称 (放得进通知标题) + 一句话用途 (面向不懂代码的管理员, 不写实现细节)。 */
    public record Entry(String label, String purpose) {}

    private static final Map<String, Entry> ENTRIES = Map.ofEntries(
            Map.entry("AttachmentObjectOutboxScheduler.drain", new Entry("附件文件清理",
                    "把已确认删除或已过期的附件文件从文件存储里真正删掉, 释放磁盘空间。")),
            Map.entry("AttachmentUploadExpiryScheduler.expire", new Entry("附件上传超时清理",
                    "清理超时未完成的附件上传, 把留下的临时文件交给附件文件清理任务删除。")),
            Map.entry("AttachmentReconciliationService.scheduledReconcile", new Entry("附件存储对账",
                    "每小时核对文件存储里的文件与附件登记是否一致, 只记录差异, 不自动删除。")),
            Map.entry("InternalStorageScratchScheduler.cleanup", new Entry("附件暂存目录清理",
                    "每小时清理附件暂存目录里遗留的临时文件。")),
            Map.entry("BusinessOutboxScheduler.drain", new Entry("业务事件派发",
                    "把审核、到货等业务事件转成站内通知和后续处理, 通知是否及时靠它。")),
            Map.entry("InventoryValueWorkScheduler.scheduled", new Entry("库存金额结算",
                    "把入库、出库引起的库存金额变动排队结算, 库存报表的金额靠它更新。")),
            Map.entry("ProductionReadinessReconciler.reconcile", new Entry("生产齐套补偿",
                    "每分钟补做漏掉的到货齐套推进, 避免物料到了生产任务却没被唤醒。")),
            Map.entry("SubcontractPreparationAutoStartReconciler.reconcile", new Entry("委外备料自动启动",
                    "每 10 分钟为还没启动前置分析的委外备料行补启动。")),
            Map.entry("MaterializedViewRefreshScheduler.refreshAll", new Entry("报表数据刷新",
                    "每 5 分钟刷新销售、采购、生产、库存、委外和应收应付的报表汇总。")),
            Map.entry("ServerStatusAlertScheduler.scan", new Entry("服务器状态告警推送",
                    "每 5 分钟检查服务器状态, 越线时给持有接收权的人发站内通知。")),
            Map.entry("CelebrationScheduler.scan", new Entry("生日与入职周年祝福",
                    "每天 08:00 扫描当天生日和入职周年的同事, 开启自动发送后代发祝福。")),
            Map.entry("DeliveryDueWarningScheduler.scan", new Entry("交货期临近预警",
                    "每天 08:23 提醒 3 天内到交货期仍未结案的销售订单。")),
            Map.entry("ReservationHoldScheduler.scan", new Entry("库存预留逾期提醒",
                    "每天 08:37 提醒交货期加宽限期已过仍占着库存的预留。")),
            Map.entry("SubcontractReturnDueScheduler.scan", new Entry("委外回厂到期提醒",
                    "每天 08:49 提醒 3 天内应回厂却还没回厂的委外单。")),
            Map.entry("SubcontractShortDeliveryOverdueScheduler.scan", new Entry("委外短交逾期提醒",
                    "每天 08:53 提醒判定为分批到货、过了预计到齐日却还没到齐的委外回厂短交。")),
            Map.entry("StockReconciliationScheduler.scan", new Entry("库存余额对账",
                    "每天 08:51 核对库存余额与出入库流水是否一致, 只告警不改账。")),
            Map.entry("AuditRetentionScheduler.runScheduled", new Entry("审计日志归档",
                    "每天 03:17 把超过保留期的审计日志移入归档, 归档再到期后清理。")),
            Map.entry("OfficialPolicyIntelligenceScheduler.refresh", new Entry("官方政策资讯刷新",
                    "每天 06:15 刷新工作台的官方政策资讯, 需要显式开启才运行。")),
            Map.entry("PrimaryHealthIndicator.ping", new Entry("云端主库连通探测",
                    "云端部署下每 10 秒探测主数据库是否可达, 不可达时自动降级为只读。"))
    );

    private ScheduledTaskCatalog() {}

    /** 登记项; 未登记的程序标识返回空 (调用方回落到程序标识, 契约测试保证线上不会发生)。 */
    public static Optional<Entry> describe(String name) {
        return name == null ? Optional.empty() : Optional.ofNullable(ENTRIES.get(name));
    }

    /** 人话名称; 未登记时原样返回程序标识, 绝不返回 null。 */
    public static String labelOf(String name) {
        return describe(name).map(Entry::label).orElse(name == null ? "" : name);
    }

    /** 已登记的全部程序标识, 供契约测试与源码对账。 */
    static Set<String> names() {
        return ENTRIES.keySet();
    }
}
