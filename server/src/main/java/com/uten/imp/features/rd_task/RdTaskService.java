package com.uten.imp.features.rd_task;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.rd_task.RdTaskContracts.RdTaskInput;
import com.uten.imp.features.rd_task.RdTaskContracts.RdTaskRow;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 工程研发部任务中心（rd_tasks）。范式镜像采购财务审批（Pattern B：JdbcTemplate + 记录）。
 *
 * <p>既是研发任务中心数据源，也承载生产「待排产 BOM 缺失」转发的等待状态：
 * <ul>
 *   <li>{@link #forwardBomGap} 由 ProductionScheduleService 调用：建 BOM 任务 + 发 {@link #EVENT_FORWARDED} 通知研发；</li>
 *   <li>{@link #resolveOpenBomTasksForGoods} 由 ChainNoticeService.notifyBomUpdated 调用（BOM 保存后）：
 *       自动完成对应 BOM 任务；通知由 ChainNoticeService 负责。</li>
 * </ul>
 */
@Service
public class RdTaskService {

    /** 转发任务事件（→ ChainNoticeService 通知 DEPT_ENG）。 */
    public static final String EVENT_FORWARDED = "RD_TASK_FORWARDED";
    /** 任务完成事件（→ ChainNoticeService 通知制单人/转发人）。 */
    public static final String EVENT_RESOLVED = "RD_TASK_RESOLVED";

    private static final String SELECT_COLUMNS = """
            SELECT t.id, t.task_no, t.title, t.category, t.status, t.priority,
                   t.goods_id, g.name AS goods_name, g.code AS goods_code,
                   t.order_item_id, t.source_doc_type, t.source_doc_id, t.source_doc_no,
                   t.assignee_employee_id, assignee.full_name AS assignee_name,
                   t.reporter_employee_id, reporter.full_name AS reporter_name,
                   t.due_date, t.started_at, t.completed_at, t.created_at, t.close_note, t.row_version
            FROM rd_tasks t
            LEFT JOIN goods g ON g.id = t.goods_id
            LEFT JOIN employees assignee ON assignee.id = t.assignee_employee_id
            LEFT JOIN employees reporter ON reporter.id = t.reporter_employee_id
            """;

    private final JdbcTemplate jdbc;
    private final DocNumberService docNumberService;
    private final BusinessEventPublisher events;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    public RdTaskService(JdbcTemplate jdbc, DocNumberService docNumberService,
                         BusinessEventPublisher events, SecurityContextCurrentUser currentUser,
                         TxSessionVars tx) {
        this.jdbc = jdbc;
        this.docNumberService = docNumberService;
        this.events = events;
        this.currentUser = currentUser;
        this.tx = tx;
    }

    @Transactional(readOnly = true)
    public PageResponse<RdTaskRow> list(String statusScope, String category, String keyword,
                                        UUID assigneeId, int page, int size) {
        int p = Math.max(1, page);
        int sz = Math.min(Math.max(1, size), 200);
        boolean done = "done".equalsIgnoreCase(statusScope);
        List<String> statuses = done ? List.of("DONE", "CANCELED") : List.of("OPEN", "IN_PROGRESS");

        List<String> where = new ArrayList<>();
        where.add("t.is_deleted = false");
        where.add("t.status IN (" + String.join(",", Collections.nCopies(statuses.size(), "?")) + ")");
        List<Object> args = new ArrayList<>(statuses);
        if (category != null && !category.isBlank()) {
            where.add("t.category = ?");
            args.add(category);
        }
        if (assigneeId != null) {
            where.add("t.assignee_employee_id = ?");
            args.add(assigneeId);
        }
        if (keyword != null && !keyword.isBlank()) {
            String kw = "%" + keyword.trim().toLowerCase() + "%";
            where.add("(LOWER(t.title) LIKE ? OR LOWER(t.task_no) LIKE ?"
                    + " OR LOWER(COALESCE(g.name,'')) LIKE ? OR LOWER(COALESCE(g.code,'')) LIKE ?)");
            args.add(kw);
            args.add(kw);
            args.add(kw);
            args.add(kw);
        }
        String whereSql = String.join(" AND ", where);

        Long total = jdbc.queryForObject(
                "SELECT COUNT(*) FROM rd_tasks t LEFT JOIN goods g ON g.id = t.goods_id WHERE " + whereSql,
                Long.class, args.toArray());
        long t = total == null ? 0 : total;

        List<Object> dataArgs = new ArrayList<>(args);
        dataArgs.add(sz);
        dataArgs.add((p - 1) * sz);
        List<RdTaskRow> items = jdbc.query(
                SELECT_COLUMNS + " WHERE " + whereSql
                        + " ORDER BY (t.priority = 'URGENT') DESC, t.created_at DESC LIMIT ? OFFSET ?",
                (rs, rowNum) -> mapRow(rs), dataArgs.toArray());

        int totalPages = t == 0 ? 0 : (int) ((t + sz - 1) / sz);
        return new PageResponse<>(items, p, sz, t, totalPages);
    }

    /** 待完成任务数（徽标）。 */
    @Transactional(readOnly = true)
    public long countOpen() {
        Long c = jdbc.queryForObject(
                "SELECT COUNT(*) FROM rd_tasks WHERE is_deleted = false AND status IN ('OPEN','IN_PROGRESS')",
                Long.class);
        return c == null ? 0 : c;
    }

    @Transactional(readOnly = true)
    public RdTaskRow get(UUID id) {
        List<RdTaskRow> rows = jdbc.query(SELECT_COLUMNS + " WHERE t.id = ? AND t.is_deleted = false",
                (rs, rowNum) -> mapRow(rs), id);
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "任务不存在");
        return rows.get(0);
    }

    @Transactional
    public RdTaskRow create(RdTaskInput input) {
        tx.bind();
        UUID actor = currentUser.requireId();
        UUID reporter = currentUser.requireEmployeeId();
        UUID id = UUID.randomUUID();
        String taskNo = docNumberService.nextNumber(DocNumberPrefix.RD_TASK);
        String priority = input.priority() == null || input.priority().isBlank() ? "NORMAL" : input.priority();
        jdbc.update("""
                INSERT INTO rd_tasks (id, task_no, title, description, category, status, priority,
                    goods_id, assignee_employee_id, reporter_employee_id, due_date, row_version, created_by, updated_by)
                VALUES (?, ?, ?, ?, ?, 'OPEN', ?, ?, ?, ?, ?, 1, ?, ?)
                """,
                id, taskNo, input.title(), input.description(), input.category(), priority,
                input.goodsId(), input.assigneeEmployeeId(), reporter, input.dueDate(), actor, actor);
        return get(id);
    }

    @Transactional
    public RdTaskRow resolve(UUID id, long expectedVersion, String note) {
        tx.bind();
        UUID actor = currentUser.requireId();
        int changed = jdbc.update("""
                UPDATE rd_tasks
                SET status = 'DONE', completed_at = now(), close_note = ?,
                    row_version = row_version + 1, updated_at = now(), updated_by = ?
                WHERE id = ? AND is_deleted = false
                  AND status IN ('OPEN','IN_PROGRESS') AND row_version = ?
                """, note, actor, id, expectedVersion);
        if (changed != 1) throw concurrentChange();
        events.publish(EVENT_RESOLVED, "RD_TASK", id, Map.of("resolverUserId", actor.toString()));
        return get(id);
    }

    @Transactional
    public RdTaskRow assign(UUID id, UUID employeeId) {
        tx.bind();
        UUID actor = currentUser.requireId();
        int changed = jdbc.update("""
                UPDATE rd_tasks
                SET assignee_employee_id = ?, updated_at = now(), updated_by = ?
                WHERE id = ? AND is_deleted = false AND status IN ('OPEN','IN_PROGRESS')
                """, employeeId, actor, id);
        if (changed != 1) throw new ApiException(ErrorCode.NOT_FOUND, "任务不存在或已结束");
        return get(id);
    }

    /**
     * 生产「BOM 缺失」转发（成品或自制组件）：按 goods_id 去重，每货品只建一个未完成 BOM 任务、
     * 只通知研发一次；所有转发人都登记进 rd_task_forwarders，研发维护好后逐个通知。
     * 由 ProductionScheduleService（单条 forwardToRd / 批量 forwardBomGapsBatch）调用。
     *
     * @param orderItemId 来源销售订单行（成品转发有值；组件转发可空）
     */
    @Transactional
    public UUID forwardBomGap(UUID orderItemId, UUID goodsId, String sourceDocType,
                              UUID sourceDocId, String sourceDocNo, String note,
                              UUID reporterEmployeeId) {
        // 按 goods_id 探测未完成 BOM 任务（每组件只一个；order_item_id 不再参与去重）。
        UUID existing = jdbc.query("""
                SELECT id FROM rd_tasks
                WHERE is_deleted = false AND category = 'BOM' AND status IN ('OPEN','IN_PROGRESS')
                  AND goods_id = ?
                ORDER BY created_at DESC LIMIT 1
                """, (rs, rn) -> rs.getObject("id", UUID.class), goodsId).stream().findFirst().orElse(null);

        UUID taskId;
        boolean isNew;
        UUID actor = currentUser.requireId();
        if (existing != null) {
            taskId = existing;
            isNew = false;
        } else {
            taskId = UUID.randomUUID();
            String taskNo = docNumberService.nextNumber(DocNumberPrefix.RD_TASK);
            try {
                jdbc.update("""
                        INSERT INTO rd_tasks (id, task_no, title, description, category, status, priority,
                            goods_id, order_item_id, source_doc_type, source_doc_id, source_doc_no,
                            reporter_employee_id, row_version, created_by, updated_by)
                        VALUES (?, ?, ?, ?, 'BOM', 'OPEN', 'NORMAL', ?, ?, ?, ?, ?, ?, 1, ?, ?)
                        """,
                        taskId, taskNo, "维护货品 BOM（生产转发）", note, goodsId, orderItemId,
                        sourceDocType, sourceDocId, sourceDocNo, reporterEmployeeId, actor, actor);
                isNew = true;
            } catch (DataIntegrityViolationException concurrent) {
                // 并发：另一事务已凭 uq_rd_tasks_open_bom(goods_id) 建任务，复用之（胜出方已发通知）。
                taskId = existingOpenBomTaskId(goodsId);
                isNew = false;
            }
        }

        // 始终把当前转发人登记进等待名单（任务新建/复用都登记；同一人同一任务不重复）。
        jdbc.update("""
                INSERT INTO rd_task_forwarders (rd_task_id, reporter_employee_id, order_item_id,
                    source_doc_type, source_doc_id, source_doc_no, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (rd_task_id, reporter_employee_id) DO NOTHING
                """,
                taskId, reporterEmployeeId, orderItemId, sourceDocType, sourceDocId, sourceDocNo, actor);

        // 仅任务首次创建时通知研发（每个组件只弹一次）。
        if (isNew) {
            events.publish(EVENT_FORWARDED, "RD_TASK", taskId, Map.of(
                    "goodsId", goodsId.toString(),
                    "reporterEmployeeId", reporterEmployeeId.toString()));
        }
        return taskId;
    }

    private UUID existingOpenBomTaskId(UUID goodsId) {
        return jdbc.query("""
                SELECT id FROM rd_tasks
                WHERE is_deleted = false AND category = 'BOM' AND status IN ('OPEN','IN_PROGRESS')
                  AND goods_id = ?
                ORDER BY created_at DESC LIMIT 1
                """, (rs, rn) -> rs.getObject("id", UUID.class), goodsId)
                .stream().findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.CONFLICT, "并发转发冲突，请重试"));
    }

    /**
     * 取某货品所有「正在等待研发维护 BOM」的计划员（员工档案 id），供研发维护完成后逐个通知。
     * 来源：rd_task_forwarders 等待名单（JOIN 未完成任务过滤）；名单为空时兜底取任务自身 reporter。
     */
    @Transactional(readOnly = true)
    public List<UUID> openBomTaskReporters(UUID goodsId) {
        List<UUID> forwarders = jdbc.queryForList("""
                SELECT DISTINCT f.reporter_employee_id
                FROM rd_task_forwarders f
                JOIN rd_tasks t ON t.id = f.rd_task_id
                WHERE t.is_deleted = false AND t.category = 'BOM'
                  AND t.status IN ('OPEN','IN_PROGRESS') AND t.goods_id = ?
                """, UUID.class, goodsId);
        if (!forwarders.isEmpty()) {
            return forwarders;
        }
        // 兜底：任务存在但无 forwarders 行（forwarders 表上线前的旧任务）。
        return jdbc.queryForList("""
                SELECT DISTINCT reporter_employee_id FROM rd_tasks
                WHERE is_deleted = false AND category = 'BOM'
                  AND status IN ('OPEN','IN_PROGRESS') AND goods_id = ?
                """, UUID.class, goodsId);
    }

    /** BOM 保存后自动完成对应未完成 BOM 任务（系统完成，无乐观锁）。返回完成条数。 */
    @Transactional
    public int resolveOpenBomTasksForGoods(UUID goodsId, String closeNote) {
        return jdbc.update("""
                UPDATE rd_tasks
                SET status = 'DONE', completed_at = now(), close_note = ?,
                    row_version = row_version + 1, updated_at = now()
                WHERE is_deleted = false AND category = 'BOM'
                  AND status IN ('OPEN','IN_PROGRESS') AND goods_id = ?
                """, closeNote, goodsId);
    }

    private RdTaskRow mapRow(ResultSet rs) throws SQLException {
        String status = rs.getString("status");
        List<String> actions = ("OPEN".equals(status) || "IN_PROGRESS".equals(status))
                ? List.of("RESOLVE", "ASSIGN") : List.of();
        return new RdTaskRow(
                rs.getObject("id", UUID.class),
                rs.getString("task_no"),
                rs.getString("title"),
                rs.getString("category"),
                status,
                rs.getString("priority"),
                rs.getObject("goods_id", UUID.class),
                rs.getString("goods_name"),
                rs.getString("goods_code"),
                rs.getObject("order_item_id", UUID.class),
                rs.getString("source_doc_type"),
                rs.getObject("source_doc_id", UUID.class),
                rs.getString("source_doc_no"),
                rs.getObject("assignee_employee_id", UUID.class),
                rs.getString("assignee_name"),
                rs.getObject("reporter_employee_id", UUID.class),
                rs.getString("reporter_name"),
                rs.getObject("due_date", LocalDate.class),
                rs.getObject("started_at", OffsetDateTime.class),
                rs.getObject("completed_at", OffsetDateTime.class),
                rs.getObject("created_at", OffsetDateTime.class),
                rs.getString("close_note"),
                rs.getLong("row_version"),
                actions);
    }

    private ApiException concurrentChange() {
        return new ApiException(ErrorCode.CONFLICT, "任务状态已变更，请刷新后重试");
    }
}
