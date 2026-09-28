package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WorkshopMaterialReportGuardPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 报工截止守卫 (ADR-131 §5.6、§10; 实现 {@link WorkshopMaterialReportGuardPort})。
 *
 * <p>只看段绑定了哪个内料仓, 不看期间料行的有效区间: 预读这些内料仓里报工日期所在的那一期,
 * 按期间 id 排序加共享锁 (与结算的排他锁互斥), 已结算就拒绝。审核时若预读到的期间正被"未审报工"
 * 拦着结算, 登记本事务提交后再试一次结算 (预读已带结算状态, 不加语句)。
 */
@Component
public class WorkshopMaterialReportGuardAdapter implements WorkshopMaterialReportGuardPort {

    private final NamedParameterJdbcTemplate db;
    private final ObjectProvider<WorkshopMaterialCloseRequester> closeRequests;
    private final SecurityContextCurrentUser currentUser;

    public WorkshopMaterialReportGuardAdapter(NamedParameterJdbcTemplate db,
                                              ObjectProvider<WorkshopMaterialCloseRequester> closeRequests,
                                              SecurityContextCurrentUser currentUser) {
        this.db = db;
        this.closeRequests = closeRequests;
        this.currentUser = currentUser;
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockAndCheck(UUID reportId, LocalDate billDate, Collection<UUID> segmentIds, Operation op) {
        if (billDate == null || segmentIds == null || segmentIds.isEmpty()) return;
        List<UUID> segments = List.copyOf(new LinkedHashSet<>(segmentIds));
        List<Map<String, Object>> periods = db.queryForList("""
                SELECT period.id, period.status, period.close_state, period.start_date, period.end_date
                FROM workshop_material_periods period
                WHERE period.id IN (
                    SELECT candidate.id FROM workshop_material_periods candidate
                    WHERE candidate.bin_warehouse_id IN (
                              SELECT DISTINCT material_row.bin_warehouse_id
                              FROM production_execution_periodic_materials material_row
                              WHERE material_row.execution_segment_id IN (:segments))
                      AND candidate.start_date <= :billDate
                      AND (candidate.end_date IS NULL OR candidate.end_date >= :billDate))
                ORDER BY period.id
                FOR SHARE
                """, new MapSqlParameterSource("segments", segments).addValue("billDate", billDate));
        for (Map<String, Object> period : periods) {
            if (!"CLOSED".equals(period.get("status"))) continue;
            LocalDate start = WorkshopMaterialBinSupport.date(period.get("start_date"));
            LocalDate end = WorkshopMaterialBinSupport.date(period.get("end_date"));
            if (op == Operation.SAVE) {
                LocalDate next = end == null ? billDate.plusDays(1) : end.plusDays(1);
                throw new ApiException(ErrorCode.CONFLICT,
                        "这个日期所在的一期车间内料仓已经结算, 报工日期请填 " + next + " 或以后");
            }
            throw new ApiException(ErrorCode.CONFLICT, start + " 至 " + end
                    + " 的车间内料仓已经结算, 不能再改这期的报工。需要改的话请找有撤销结算权限的人 ("
                    + reopeners() + ") 撤销后再改");
        }
        if (op == Operation.APPROVE) {
            WorkshopMaterialCloseRequester requester = closeRequests.getIfAvailable();
            UUID actor = currentUser.id().orElse(null);
            if (requester == null || actor == null) return;
            for (Map<String, Object> period : periods) {
                if ("COUNTED".equals(period.get("status")) && "BLOCKED".equals(period.get("close_state"))) {
                    requester.requestAfterCommit((UUID) period.get("id"), actor);
                }
            }
        }
    }

    /** 持"撤销车间内料仓结算"权限 (只能逐人授予) 的在职人员姓名。 */
    private String reopeners() {
        List<String> names = db.queryForList("""
                SELECT DISTINCT employee.full_name
                FROM user_permission_overrides grant_row
                JOIN permissions permission ON permission.id = grant_row.permission_id
                 AND permission.code = 'workshop_material:reopen'
                JOIN users account ON account.id = grant_row.user_id AND NOT account.is_deleted
                 AND account.status = 'active'
                JOIN employees employee ON employee.id = account.employee_id AND NOT employee.is_deleted
                WHERE grant_row.effect = 'grant' AND COALESCE(grant_row.active, TRUE)
                ORDER BY employee.full_name
                LIMIT 5
                """, Map.of(), String.class);
        return names.isEmpty() ? "请系统管理员指定" : String.join("、", names);
    }
}
