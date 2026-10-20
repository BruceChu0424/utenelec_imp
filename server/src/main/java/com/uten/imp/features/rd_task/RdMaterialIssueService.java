package com.uten.imp.features.rd_task;

import com.uten.imp.application.port.RdMaterialIssuePort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Separate from missing-subcontract-BOM tasks: saving any BOM must not close a missing-unit repair. */
@Service
public final class RdMaterialIssueService implements RdMaterialIssuePort {
    private final JdbcTemplate jdbc;
    private final DocNumberService numbers;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final TransactionTemplate transaction;
    private final com.uten.imp.application.port.GoodsMasterWriteAccessPort goodsAccess;
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private com.uten.imp.application.port.BusinessEventPublisher events;

    public RdMaterialIssueService(JdbcTemplate jdbc, DocNumberService numbers,
            SecurityContextCurrentUser current, TxSessionVars tx, PlatformTransactionManager transactions,
            com.uten.imp.application.port.GoodsMasterWriteAccessPort goodsAccess) {
        this.jdbc = jdbc;
        this.numbers = numbers;
        this.current = current;
        this.tx = tx;
        this.goodsAccess=goodsAccess;
        transaction = new TransactionTemplate(transactions);
        transaction.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRED);
    }

    @Override
    public Map<String, String> openTaskNos(Collection<Target> targets) {
        if (targets.isEmpty()) return Map.of();
        var named = new NamedParameterJdbcTemplate(jdbc);
        var params = new MapSqlParameterSource("goods", targets.stream().map(Target::goodsId).distinct().toList())
                .addValue("sources", List.of(MASTER_SOURCE, BOM_SOURCE));
        Map<String, String> result = new LinkedHashMap<>();
        named.query("""
                SELECT goods_id,source_doc_type,task_no FROM rd_tasks
                WHERE goods_id IN (:goods) AND source_doc_type IN (:sources)
                  AND category='OTHER' AND status IN ('OPEN','IN_PROGRESS') AND is_deleted=FALSE
                ORDER BY created_at DESC,id
                """, params, rs -> {
            result.putIfAbsent(rs.getString("source_doc_type") + ":" + rs.getObject("goods_id"), rs.getString("task_no"));
        });
        return Map.copyOf(result);
    }

    public void reconcileBasicUnit(UUID taskId,RdTaskContracts.InitialBasicUnitRequest request) {
        transaction.executeWithoutResult(status -> {
            tx.bind();
            var actor=current.get().orElseThrow();
            if (!actor.isSuperAdmin() && !actor.getPermissions().containsAll(java.util.Set.of(
                    "rd_task:view","goods:view","goods:edit","unit:view"))) {
                throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN,"当前账号没有首次单位核对权限");
            }
            List<Map<String,Object>> tasks=jdbc.queryForList("SELECT assignee_employee_id,goods_id FROM rd_tasks WHERE id=? AND NOT is_deleted FOR UPDATE",taskId);
            if(tasks.isEmpty()) throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND,"任务不存在");
            Object assignee=tasks.getFirst().get("assignee_employee_id");
            if(!actor.isSuperAdmin() && assignee!=null && !assignee.equals(current.requireEmployeeId())) {
                throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN,"该任务已指派其他办理人");
            }
            UUID goodsId=(UUID)tasks.getFirst().get("goods_id");
            if(jdbc.queryForList("SELECT id FROM goods WHERE id=? AND NOT is_deleted FOR UPDATE",UUID.class,goodsId).isEmpty()) {
                throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND,"货品不存在");
            }
            goodsAccess.requireWritable(goodsId);
            try {
                Integer changed=jdbc.queryForObject("SELECT fn_reconcile_goods_initial_basic_unit(?,?,?,?,?)",Integer.class,
                        taskId,request.expectedVersion(),request.unitId(),request.evidence(),current.requireId());
                if(changed!=null && changed==1 && events!=null) events.publish(RdTaskService.EVENT_RESOLVED,"RD_TASK",taskId,
                        Map.of("resolverUserId",current.requireId().toString()));
            } catch(org.springframework.dao.DataIntegrityViolationException invalid) {
                String message=invalid.getMostSpecificCause().getMessage();
                int where=message==null?-1:message.indexOf('\n');
                if(where>=0) message=message.substring(0,where);
                if(message!=null) message=message.replaceFirst("^ERROR: ","");
                throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,
                        message==null?"核对条件已变化，请重新加载任务":message);
            }
        });
    }

    /** One targeted preflight when the dialog opens, never a quantity-history scan for every list row. */
    public RdTaskContracts.InitialBasicUnitContext initialBasicUnitContext(UUID taskId) {
        return transaction.execute(status -> {
            var actor=current.get().orElseThrow();
            if(!actor.isSuperAdmin() && !actor.getPermissions().containsAll(java.util.Set.of("rd_task:view","goods:view","goods:edit","unit:view"))) {
                throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN,"当前账号没有首次单位核对权限");
            }
            List<Map<String,Object>> tasks=jdbc.queryForList("""
                    SELECT t.goods_id,t.assignee_employee_id,t.status,g.unit_id,t.source_doc_type,t.category,
                           legacy.id AS legacy_unit_id,legacy.is_deleted AS legacy_deleted,legacy.status AS legacy_status
                    FROM rd_tasks t JOIN goods g ON g.id=t.goods_id AND NOT g.is_deleted
                    LEFT JOIN units legacy ON legacy.legacy_id=NULLIF(g.unit_legacy_id,0)
                    WHERE t.id=? AND NOT t.is_deleted
                    """,taskId);
            if(tasks.isEmpty()) throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND,"任务不存在");
            var task=tasks.getFirst();
            if(!actor.isSuperAdmin() && task.get("assignee_employee_id")!=null
                    && !task.get("assignee_employee_id").equals(current.requireEmployeeId())) {
                throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN,"该任务已指派其他办理人");
            }
            UUID goodsId=(UUID)task.get("goods_id");
            goodsAccess.requireWritable(goodsId);
            if(!MASTER_SOURCE.equals(task.get("source_doc_type")) || !"OTHER".equals(task.get("category"))
                    || !List.of("OPEN","IN_PROGRESS").contains(task.get("status"))) {
                return new RdTaskContracts.InitialBasicUnitContext(false,"任务已变化，请重新加载");
            }
            if(task.get("unit_id")!=null) return new RdTaskContracts.InitialBasicUnitContext(false,"已有基本单位不能通过首次核对更换");
            if(Boolean.TRUE.equals(jdbc.queryForObject("SELECT fn_goods_non_bom_quantity_in_use(?)",Boolean.class,goodsId))) {
                return new RdTaskContracts.InitialBasicUnitContext(false,"已有BOM以外的数量事实，不能在此补历史单位；请按原始单据受控核对或修正BOM货品映射");
            }
            if(task.get("legacy_unit_id")!=null && (Boolean.TRUE.equals(task.get("legacy_deleted")) || !"使用".equals(task.get("legacy_status")))) {
                return new RdTaskContracts.InitialBasicUnitContext(false,"原历史单位已停用或删除，请先受控恢复原单位，不能另选单位替代历史桥接");
            }
            return new RdTaskContracts.InitialBasicUnitContext(true,null);
        });
    }

    @Override
    public String forward(Target target, UUID analysisId, String description) {
        return transaction.execute(status -> {
            tx.bind();
            // Every creator uses this same lock: repeated clicks and concurrent planners reuse one open task.
            jdbc.queryForObject("SELECT pg_advisory_xact_lock(hashtextextended(?,0))", Object.class, target.key());
            List<Map<String, Object>> open = jdbc.queryForList("""
                    SELECT id,task_no FROM rd_tasks WHERE goods_id=? AND source_doc_type=?
                      AND category='OTHER' AND status IN ('OPEN','IN_PROGRESS') AND is_deleted=FALSE
                    ORDER BY created_at,id LIMIT 1 FOR UPDATE
                    """, target.goodsId(), target.sourceType());
            UUID taskId;
            String taskNo;
            if (open.isEmpty()) {
                taskId = UUID.randomUUID();
                taskNo = numbers.nextNumber(DocNumberPrefix.RD_TASK);
                int inserted = jdbc.update("""
                        INSERT INTO rd_tasks(id,task_no,title,description,category,status,priority,goods_id,
                            source_doc_type,source_doc_id,reporter_employee_id,created_by,updated_by)
                        SELECT ?,?,LEFT(? || COALESCE(name,'') || '(' || COALESCE(code,'') || ')',200),?,
                            'OTHER','OPEN','NORMAL',id,?,?,?,?,? FROM goods WHERE id=?
                        """, taskId, taskNo, target.masterData() ? "修复货品资料：" : "修复 BOM：", description,
                        target.sourceType(), analysisId, current.requireEmployeeId(), current.requireId(),
                        current.requireId(), target.goodsId());
                if (inserted != 1) throw new com.uten.imp.common.web.ApiException(
                        com.uten.imp.common.web.ErrorCode.NOT_FOUND, "货品已变化，请重新检查后再转工程部");
            } else {
                taskId = (UUID) open.getFirst().get("id");
                taskNo = String.valueOf(open.getFirst().get("task_no"));
                // Keep additional source evidence when another planner reports the same repair target.
                jdbc.update("""
                        UPDATE rd_tasks SET description=CASE WHEN strpos(COALESCE(description,''),?)>0
                            THEN description ELSE COALESCE(description,'') || E'\n\n' || ? END,
                            updated_at=now(),updated_by=? WHERE id=?
                        """, description, description, current.requireId(), taskId);
            }
            jdbc.update("""
                    INSERT INTO rd_task_forwarders(rd_task_id,reporter_employee_id,source_doc_type,source_doc_id,created_by)
                    VALUES(?,?,?,?,?) ON CONFLICT(rd_task_id,reporter_employee_id) DO NOTHING
                    """, taskId, current.requireEmployeeId(), target.sourceType(), analysisId, current.requireId());
            return taskNo;
        });
    }
}
