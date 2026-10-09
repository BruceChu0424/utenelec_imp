package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.BusinessOutboxDomainHandler;
import com.uten.imp.application.port.WorkshopStockCountPostingPort;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** Transactional outbox delivery: current permissions and warehouse scope select reviewers. */
@Component
public class StockCountNoticeHandler implements BusinessOutboxDomainHandler {
    static final String AGGREGATE = "STOCK_COUNT_REQUEST";
    static final String FINANCE_EVENT = "STOCK_COUNT_PENDING_FINANCE_REVIEW";
    static final String WAREHOUSE_EVENT = "STOCK_COUNT_PENDING_WAREHOUSE_REVIEW";
    private final JdbcTemplate db;
    private final NoticeService notices;
    private final NoticePermissionCandidateQuery candidates;
    private final UserAccountRepository users;
    private final PermissionResolver permissions;
    private final WorkshopStockCountPostingPort workshop;
    private final WarehouseNoticeRouter warehouseRouter;

    public StockCountNoticeHandler(JdbcTemplate db, NoticeService notices, NoticePermissionCandidateQuery candidates,
            UserAccountRepository users, PermissionResolver permissions, WorkshopStockCountPostingPort workshop,
            WarehouseNoticeRouter warehouseRouter) {
        this.db = db; this.notices = notices; this.candidates = candidates; this.users = users;
        this.permissions = permissions; this.workshop = workshop; this.warehouseRouter = warehouseRouter;
    }

    @Override public boolean supports(String eventType) {
        return Set.of("STOCK_COUNT_SUBMITTED", "STOCK_COUNT_APPROVED", "STOCK_COUNT_REJECTED", "STOCK_COUNT_CANCELLED")
                .contains(eventType);
    }

    @Override public void handle(UUID outboxEventId, String eventType, UUID requestId, JsonNode payload, UUID createdBy) {
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT request.id, request.request_no, request.warehouse_id, warehouse.name AS warehouse_name,
                       request.review_route, request.status, request.submitted_by, request.review_reason
                FROM stock_count_requests request JOIN warehouses warehouse ON warehouse.id = request.warehouse_id
                WHERE request.id = ? FOR SHARE OF request
                """, requestId);
        if (rows.isEmpty()) return;
        Map<String, Object> request = rows.getFirst();
        String status = Objects.toString(request.get("status"));
        String label = request.get("request_no") + " · " + request.get("warehouse_name");
        boolean warehouse = "WAREHOUSE".equals(request.get("review_route"));
        if ("STOCK_COUNT_SUBMITTED".equals(eventType)) {
            if (!"PENDING".equals(status)) return; // Approval/cancellation won before the worker delivered submission.
            String authority = warehouse ? "stock:count:warehouse_review" : "stock:count:finance_review";
            List<UserAccount> possible = candidates.possibleUsers(Set.of(authority)).map(users::findAllById).orElseGet(users::findAll);
            // 池 = 在职、真实持有通知与审核权限(超管全量镜像不算任务归属, 2026-10-09 ADR-063 追加修订;
            // 仓库路由另须能看这个仓)的人。仓库路由的盘点审核卡再经 ADR-149
            // 唯一分发规则: 该仓子仓负责人 ∩ 池; 没有则主管 ∩ 池; 再没有才发整个池。财务路由仍按权限全员。
            java.util.LinkedHashSet<UUID> pool = new java.util.LinkedHashSet<>();
            for (UserAccount user : possible) {
                if (!active(user)) continue;
                Set<String> current = permissions.grantedPermsOf(user);
                if (!current.contains("notice:read") || !current.contains(authority)) continue;
                if (warehouse && !workshop.canAccessWarehouseForUser((UUID) request.get("warehouse_id"), user.getId())) continue;
                pool.add(user.getId());
            }
            List<UUID> recipients = warehouse
                    ? warehouseRouter.recipients(pool, List.of((UUID) request.get("warehouse_id")))
                    : List.copyOf(pool);
            for (UUID recipient : recipients) {
                notices.publishForUser(recipient, "盘点待审核：" + label,
                        "请核对盘点的原数量、目标数量、重量和差额；审核通过后才更新库存。",
                        "approval", "库存盘点", (warehouse ? "/warehouse/stock-count-review" : "/finance/stock-count-review")
                                + "?requestId=" + requestId,
                        warehouse ? WAREHOUSE_EVENT : FINANCE_EVENT, "important", requestId);
            }
            return;
        }
        if ("PENDING".equals(status)) return;
        notices.resolveReviewNotices(AGGREGATE, requestId, status);
        String expected = eventType.substring("STOCK_COUNT_".length());
        if (!expected.equals(status)) return;
        users.findById((UUID) request.get("submitted_by")).filter(StockCountNoticeHandler::active).ifPresent(user -> {
            Set<String> current = permissions.grantedPermsOf(user);
            if (!current.containsAll(Set.of("notice:read", "stock:count:submit"))) return;
            String outcome = switch (status) { case "APPROVED" -> "已通过"; case "REJECTED" -> "已退回"; default -> "已撤回"; };
            notices.publishForUser(user.getId(), "盘点" + outcome + "：" + label,
                    ("APPROVED".equals(status) ? "库存已按审核结果更新。" : "库存未因本次申请改变。")
                            + Objects.toString(request.get("review_reason"), ""),
                    "workflow", "库存盘点", "/stock/count-requests?requestId=" + requestId,
                    eventType, "normal", null);
        });
    }

    private static boolean active(UserAccount user) {
        return user != null && !user.isDeleted() && "active".equals(user.getStatus()) && user.getEmployeeId() != null;
    }
}
