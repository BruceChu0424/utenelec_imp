package com.uten.imp.features.notice;

import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.springframework.transaction.TransactionDefinition.PROPAGATION_REQUIRES_NEW;

/**
 * 业务链自动通知（SOP §一 8 类：排产/完工/部分完工/数量不足补产/发货/驳回/延期预警/取消确认/缺料）。
 *
 * <p><b>旁路原则</b>：所有发送都推迟到主事务提交后（afterCommit）执行，且在独立新事务
 * （REQUIRES_NEW）中读数+落库，单个接收人失败只记日志，绝不影响主业务事务。
 *
 * <p>接收人解析：订单归属销售（owner_employee_id，回退 seller_id）→ 员工账号；
 * 采购/调度按角色码（buyer/planner）广播。业务 Service 只传单据 ID，内容在此统一按 ID 自查组装。
 */
@Slf4j
@Service
public class ChainNoticeService {

    /** 合法类型见 NoticeService.TYPES；此处固定用到的子集。 */
    public static final String TYPE_WORKFLOW = "workflow";
    public static final String TYPE_TASK = "task";
    public static final String TYPE_URGENT = "urgent";

    private static final String PUBLISHER = "系统";

    private final NoticeService noticeService;
    private final UserAccountRepository userRepo;
    private final UserRoleRepository userRoleRepo;
    private final JdbcTemplate jdbc;
    private final TransactionTemplate newTx;

    public ChainNoticeService(NoticeService noticeService,
                              UserAccountRepository userRepo,
                              UserRoleRepository userRoleRepo,
                              JdbcTemplate jdbc,
                              PlatformTransactionManager txManager) {
        this.noticeService = noticeService;
        this.userRepo = userRepo;
        this.userRoleRepo = userRoleRepo;
        this.jdbc = jdbc;
        this.newTx = new TransactionTemplate(txManager);
        this.newTx.setPropagationBehavior(PROPAGATION_REQUIRES_NEW);
    }

    // ---------- 8 类通知入口（业务 Service 一行调用） ----------

    /** ① 排产通知销售：计划单审核后，按订单聚合本次排产量。shortage=true 时另发缺料通知（⑧）。 */
    public void notifyPlanScheduled(UUID planId, boolean shortage) {
        afterCommit(() -> {
            String planNo = str(one("SELECT bill_no FROM production_plans WHERE id = ?", planId));
            Map<UUID, BigDecimal> byOrder = new LinkedHashMap<>();
            Map<UUID, String> goodsByOrder = new LinkedHashMap<>();
            for (Map<String, Object> r : jdbc.queryForList("""
                    SELECT oi.order_id, SUM(l.allocated_qty) AS qty, g.code AS goods
                    FROM plan_order_item_links l
                    JOIN sales_order_items oi ON oi.id = l.order_item_id
                    JOIN production_plan_items pi ON pi.id = l.plan_item_id
                    LEFT JOIN goods g ON g.id = pi.goods_id
                    WHERE pi.plan_id = ? AND l.is_deleted = false AND l.source = 0
                    GROUP BY oi.order_id, g.code
                    """, planId)) {
                UUID orderId = (UUID) r.get("order_id");
                byOrder.merge(orderId, bd(r.get("qty")), BigDecimal::add);
                goodsByOrder.merge(orderId, str(r.get("goods")), (a, b) -> a + "/" + b);
            }
            for (var e : byOrder.entrySet()) {
                OrderRef o = orderRef(e.getKey());
                if (o == null) continue;
                notifyUser(o.ownerUserId(), TYPE_WORKFLOW,
                        "排产通知：" + o.billNo(),
                        "订单 " + o.billNo() + " 货品 " + goodsByOrder.get(e.getKey())
                                + " 已排产 " + qty(e.getValue()) + "（计划单 " + planNo + "）。");
            }
            if (shortage) {
                notifyRoles(List.of("buyer", "planner"), TYPE_TASK,
                        "缺料提醒：" + planNo,
                        "计划单 " + planNo + " 审核后 BOM 净需求不足（订单行状态=待物料），请采购/调度跟进备料。");
            }
        });
    }

    /** ②③ 完工/部分完工通知销售：成品入库审核后，按本单补的预留溯源订单行。 */
    public void notifyFinishedInbound(UUID stockDocId) {
        afterCommit(() -> {
            String docNo = str(one("SELECT bill_no FROM stock_documents WHERE id = ?", stockDocId));
            for (Map<String, Object> r : jdbc.queryForList("""
                    SELECT oi.order_id, rv.qty, oi.produced_qty, oi.qty AS order_qty,
                           oi.chain_status, g.code AS goods
                    FROM stock_reservations rv
                    JOIN sales_order_items oi ON oi.id = rv.order_item_id
                    LEFT JOIN goods g ON g.id = oi.goods_id
                    WHERE rv.source_doc_type = 'PRODUCTION_INBOUND' AND rv.source_doc_id = ?
                    """, stockDocId)) {
                OrderRef o = orderRef((UUID) r.get("order_id"));
                if (o == null) continue;
                boolean full = r.get("chain_status") != null && ((Number) r.get("chain_status")).shortValue() == 7;
                notifyUser(o.ownerUserId(), TYPE_WORKFLOW,
                        (full ? "完工通知：" : "部分完工：") + o.billNo(),
                        "订单 " + o.billNo() + " 货品 " + str(r.get("goods")) + " 完工入库 " + qty(bd(r.get("qty")))
                                + "（入库单 " + docNo + "），累计完工 " + qty(bd(r.get("produced_qty")))
                                + "/订货 " + qty(bd(r.get("order_qty"))) + (full ? "，已可发货。" : "。"));
            }
        });
    }

    /** ④ 数量不足（补产）通知销售：报工完结缺额自动生成补产计划后。 */
    public void notifyRemakeCreated(String reportBillNo) {
        afterCommit(() -> {
            for (Map<String, Object> r : jdbc.queryForList("""
                    SELECT oi.order_id, rp.bill_no AS plan_no, SUM(rl.allocated_qty) AS qty
                    FROM production_plans rp
                    JOIN production_plan_items ri ON ri.plan_id = rp.id
                    JOIN plan_order_item_links rl ON rl.plan_item_id = ri.id AND rl.is_deleted = false AND rl.source = 1
                    JOIN sales_order_items oi ON oi.id = rl.order_item_id
                    WHERE rp.source_doc_no = ?
                    GROUP BY oi.order_id, rp.bill_no
                    """, reportBillNo)) {
                OrderRef o = orderRef((UUID) r.get("order_id"));
                if (o == null) continue;
                notifyUser(o.ownerUserId(), TYPE_TASK,
                        "数量不足·已补产：" + o.billNo(),
                        "订单 " + o.billNo() + " 报工完结缺额 " + qty(bd(r.get("qty")))
                                + "，已自动生成补产计划 " + str(r.get("plan_no")) + "（报工单 " + reportBillNo
                                + "），待调度审核排产。");
            }
        });
    }

    /** ⑤ 发货通知销售：出货单审核后，按订单聚合本次出货量。（出货单暂无物流单号字段，内容含单号/数量/仓库。） */
    public void notifyShipmentApproved(UUID shipmentId) {
        afterCommit(() -> {
            Map<String, Object> h = one("SELECT bill_no, warehouse_id FROM sales_shipments WHERE id = ?", shipmentId);
            if (h == null) return;
            String wh = str(one("SELECT name FROM warehouses WHERE id = ?", h.get("warehouse_id")));
            Map<UUID, BigDecimal> byOrder = new LinkedHashMap<>();
            for (Map<String, Object> r : jdbc.queryForList("""
                    SELECT oi.order_id, SUM(si.qty) AS qty
                    FROM sales_shipment_items si
                    JOIN sales_order_items oi ON oi.id = si.order_item_id
                    WHERE si.shipment_id = ?
                    GROUP BY oi.order_id
                    """, shipmentId)) {
                byOrder.merge((UUID) r.get("order_id"), bd(r.get("qty")), BigDecimal::add);
            }
            for (var e : byOrder.entrySet()) {
                OrderRef o = orderRef(e.getKey());
                if (o == null) continue;
                notifyUser(o.ownerUserId(), TYPE_WORKFLOW,
                        "发货通知：" + o.billNo(),
                        "订单 " + o.billNo() + " 已发货 " + qty(e.getValue()) + "（出货单 " + str(h.get("bill_no"))
                                + (wh.isEmpty() ? "" : "，仓库 " + wh) + "）。");
            }
        });
    }

    /** ⑥ 驳回通知销售：仓库驳回出货单（草稿）后，按订单聚合缺口量。 */
    public void notifyShipmentRejected(UUID shipmentId, String reason) {
        afterCommit(() -> {
            String billNo = str(one("SELECT bill_no FROM sales_shipments WHERE id = ?", shipmentId));
            for (Map<String, Object> r : jdbc.queryForList("""
                    SELECT oi.order_id, SUM(si.qty) AS qty
                    FROM sales_shipment_items si
                    JOIN sales_order_items oi ON oi.id = si.order_item_id
                    WHERE si.shipment_id = ? AND si.order_item_id IS NOT NULL
                    GROUP BY oi.order_id
                    """, shipmentId)) {
                OrderRef o = orderRef((UUID) r.get("order_id"));
                if (o == null) continue;
                notifyUser(o.ownerUserId(), TYPE_URGENT,
                        "出货驳回：" + o.billNo(),
                        "出货单 " + billNo + " 被仓库驳回（" + (reason == null || reason.isBlank() ? "备货异常" : reason)
                                + "），订单 " + o.billNo() + " 缺口 " + qty(bd(r.get("qty")))
                                + " 已释放预留并回到调度待排产。");
            }
        });
    }

    /** ⑦ 取消确认：订单整单取消后，确认销售 + 通知调度不用排。 */
    public void notifyOrderCanceled(UUID orderId) {
        afterCommit(() -> {
            OrderRef o = orderRef(orderId);
            if (o == null) return;
            notifyUser(o.ownerUserId(), TYPE_WORKFLOW,
                    "取消确认：" + o.billNo(),
                    "订单 " + o.billNo() + " 已整单取消：全部预留已释放（已产成品回通用库存），排产联动已断开。");
            notifyRoles(List.of("planner"), TYPE_WORKFLOW,
                    "订单取消·无需排产：" + o.billNo(),
                    "订单 " + o.billNo() + " 已取消，相关排产联动已断开，请调度停止/忽略该单后续排产。");
        });
    }

    /** ⑦.5 新订单待排产：订单审核后通知调度（planner），生产部工作台徽标同源（待排产计数）。 */
    public void notifyOrderApproved(UUID orderId) {
        afterCommit(() -> {
            OrderRef o = orderRef(orderId);
            if (o == null) return;
            Map<String, Object> agg = one("""
                    SELECT COUNT(*) AS lines,
                           MIN(COALESCE(i.deliver_date, oo.deliver_date)) AS deliver,
                           string_agg(DISTINCT g.code, ' / ') AS goods
                    FROM sales_order_items i
                    JOIN sales_orders oo ON oo.id = i.order_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    WHERE i.order_id = ? AND i.is_deleted = false
                    """, orderId);
            String lines = agg == null ? "?" : str(agg.get("lines"));
            Object d = agg == null ? null : agg.get("deliver");
            String deliver = d == null ? "未定" : d.toString();
            String goods = agg == null || agg.get("goods") == null ? "" : str(agg.get("goods"));
            notifyRoles(List.of("planner"), TYPE_TASK,
                    "新订单待排产：" + o.billNo(),
                    "订单 " + o.billNo() + " 已审核，共 " + lines + " 行货品（" + goods
                            + "）待排产，最早交货日 " + deliver + "，请到「生产调度」处理。");
        });
    }

    /** ⑧ 延期预警（每日扫描调用）：交货 ≤3 天未结案订单，通知业务员 + 调度。 */
    public void notifyDeliveryDue(UUID orderId, long daysLeft) {
        OrderRef o = orderRef(orderId);
        if (o == null) return;
        String when = daysLeft < 0 ? "已超期 " + (-daysLeft) + " 天"
                : daysLeft == 0 ? "今日交货" : "距交货 " + daysLeft + " 天";
        String title = "交货预警：" + o.billNo();
        String content = "订单 " + o.billNo() + " " + when + "，尚未结案，请跟进生产/发货进度。";
        Set<UUID> targets = new LinkedHashSet<>();
        if (o.ownerUserId() != null) targets.add(o.ownerUserId());
        targets.addAll(userRoleRepo.findUserIdsByRoleCode("planner"));
        for (UUID uid : targets) {
            sendToUser(uid, TYPE_URGENT, title, content);
        }
    }

    /** ⑧ 延期预警（调度器入口）：同一订单同一接收人同日只发一条（notices 标题+接收人+当日去重）。 */
    public void notifyDeliveryDueIfNotSentToday(UUID orderId, long daysLeft) {
        try {
            OrderRef o = orderRef(orderId);
            if (o == null) return;
            String title = "交货预警：" + o.billNo();
            Instant startOfToday = LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant();
            String when = daysLeft < 0 ? "已超期 " + (-daysLeft) + " 天"
                    : daysLeft == 0 ? "今日交货" : "距交货 " + daysLeft + " 天";
            String content = "订单 " + o.billNo() + " " + when + "，尚未结案，请跟进生产/发货进度。";
            Set<UUID> targets = new LinkedHashSet<>();
            if (o.ownerUserId() != null) targets.add(o.ownerUserId());
            targets.addAll(userRoleRepo.findUserIdsByRoleCode("planner"));
            for (UUID uid : targets) {
                Boolean sent = jdbc.queryForObject(
                        "SELECT EXISTS(SELECT 1 FROM notices WHERE audience_user_id = ? AND title = ? AND published_at >= ?)",
                        Boolean.class, uid, title, startOfToday);
                if (Boolean.TRUE.equals(sent)) continue;
                sendToUser(uid, TYPE_URGENT, title, content);
            }
        } catch (Exception e) {
            log.warn("延期预警单发失败 order={}: {}", orderId, e.toString());
        }
    }

    // ---------- 接收人解析与发送 ----------

    /** 订单快照：单号 + 归属销售的用户账号（owner_employee_id 优先，回退 seller_id）。 */
    private OrderRef orderRef(UUID orderId) {
        Map<String, Object> r = one(
                "SELECT bill_no, owner_employee_id, seller_id FROM sales_orders WHERE id = ?", orderId);
        if (r == null) return null;
        UUID userId = userIdOfEmployee((UUID) r.get("owner_employee_id"));
        if (userId == null) userId = userIdOfEmployee((UUID) r.get("seller_id"));
        return new OrderRef(str(r.get("bill_no")), userId);
    }

    private record OrderRef(String billNo, UUID ownerUserId) {}

    /** 员工 → 活跃账号（无账号/已停用/已删除 → null，静默跳过）。 */
    private UUID userIdOfEmployee(UUID employeeId) {
        if (employeeId == null) return null;
        return userRepo.findByEmployeeId(employeeId)
                .filter(u -> "active".equals(u.getStatus()) && !u.isDeleted())
                .map(UserAccount::getId)
                .orElse(null);
    }

    private void notifyUser(UUID userId, String type, String title, String content) {
        if (userId == null) return;
        sendToUser(userId, type, title, content);
    }

    private void notifyRoles(List<String> roleCodes, String type, String title, String content) {
        Set<UUID> targets = new LinkedHashSet<>();
        for (String code : roleCodes) {
            targets.addAll(userRoleRepo.findUserIdsByRoleCode(code));
        }
        for (UUID uid : targets) {
            sendToUser(uid, type, title, content);
        }
    }

    /** 单发：逐人隔离异常（一个接收人失败不影响其他人）；停用/删除账号跳过。 */
    private void sendToUser(UUID userId, String type, String title, String content) {
        try {
            UserAccount u = userRepo.findById(userId).orElse(null);
            if (u == null || !"active".equals(u.getStatus()) || u.isDeleted()) return;
            noticeService.publishForUser(userId, title, content, type, PUBLISHER);
        } catch (Exception e) {
            log.warn("业务链通知单发失败 user={} title={}: {}", userId, title, e.toString());
        }
    }

    // ---------- 旁路执行 ----------

    /** 主事务提交后在独立新事务中执行；无事务则直接执行。任何异常只记日志。 */
    private void afterCommit(Runnable task) {
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override
                public void afterCommit() {
                    safeRun(() -> newTx.executeWithoutResult(s -> task.run()));
                }
            });
        } else {
            safeRun(task);
        }
    }

    private void safeRun(Runnable task) {
        try {
            task.run();
        } catch (Exception e) {
            log.warn("业务链通知发送失败（不影响主业务）: {}", e.toString());
        }
    }

    // ---------- 查询小工具 ----------

    private Map<String, Object> one(String sql, Object... args) {
        List<Map<String, Object>> rows = jdbc.queryForList(sql, args);
        return rows.isEmpty() ? null : rows.get(0);
    }

    private static String str(Object v) {
        return v == null ? "" : v.toString();
    }

    private static BigDecimal bd(Object v) {
        return v instanceof BigDecimal b ? b : BigDecimal.ZERO;
    }

    private static String qty(BigDecimal v) {
        return v.stripTrailingZeros().toPlainString();
    }
}
