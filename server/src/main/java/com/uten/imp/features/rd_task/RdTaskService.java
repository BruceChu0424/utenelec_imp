package com.uten.imp.features.rd_task;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.rd_task.RdTaskContracts.RdTaskRow;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
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
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/**
 * 工程研发部任务中心（rd_tasks）。范式镜像采购财务审批（Pattern B：JdbcTemplate + 记录）。
 *
 * <p>既是研发任务中心数据源，也承载「委外件缺 BOM」任务的等待名单(ADR-143 §二.3)：
 * <ul>
 *   <li>建任务与登记等待人在 {@link RdBomGapService}(物料分析、委外订货发现委外件没有可发外直属物料时)；</li>
 *   <li>{@link #openBomTaskWaiters} / {@link #resolveOpenBomTasksForGoods} 由 ChainNoticeService.notifyBomUpdated
 *       调用（BOM 保存后）：取等待名单、自动完成对应 BOM 任务；通知由 ChainNoticeService 负责。</li>
 * </ul>
 */
@Service
public class RdTaskService {

    /** 任务完成事件（→ ChainNoticeService 通知制单人/转发人）。 */
    public static final String EVENT_RESOLVED = "RD_TASK_RESOLVED";

    private static final String SELECT_COLUMNS = """
            SELECT t.id, t.task_no, t.title, t.category, t.status, t.priority,
                   t.goods_id, g.name AS goods_name, g.code AS goods_code,
                   goods_color.name AS color_name,
                   t.order_item_id, t.source_doc_type, t.source_doc_id, t.source_doc_no,
                   t.assignee_employee_id, assignee.full_name AS assignee_name,
                   t.reporter_employee_id, reporter.full_name AS reporter_name,
                   t.due_date, t.started_at, t.completed_at, t.created_at, t.close_note, t.row_version
            FROM rd_tasks t
            LEFT JOIN goods g ON g.id = t.goods_id
            -- 任务只指到货品，颜色只能取主档色；不参与过滤/排序，纯身份展示列。
            LEFT JOIN colors goods_color ON goods_color.id = g.color_id
                                        AND goods_color.is_deleted = FALSE
            LEFT JOIN employees assignee ON assignee.id = t.assignee_employee_id
            LEFT JOIN employees reporter ON reporter.id = t.reporter_employee_id
            """;

    private final JdbcTemplate jdbc;
    private final BusinessEventPublisher events;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    public RdTaskService(JdbcTemplate jdbc,
                         BusinessEventPublisher events, SecurityContextCurrentUser currentUser,
                         TxSessionVars tx) {
        this.jdbc = jdbc;
        this.events = events;
        this.currentUser = currentUser;
        this.tx = tx;
    }

    @Transactional(readOnly = true)
    public PageResponse<RdTaskRow> list(String statusScope, String category, String keyword,
                                        UUID assigneeId, int page, int size) {
        int p = Math.max(1, page);
        int sz = Math.min(Math.max(1, size), 200);
        List<String> statuses = scopeStatuses(statusScope);

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

    /**
     * 列表分段的状态集。「待完成」自 ADR-100 起在页内拆成「待处理」与「进行中」两段，
     * 各自要能点进去，所以在旧的 open/done 两档之外再认两个单档；
     * {@code open} 仍是两档合集，默认值与老调用点一个字不用改。
     */
    private static List<String> scopeStatuses(String statusScope) {
        String scope = statusScope == null ? "" : statusScope.strip().toLowerCase(Locale.ROOT);
        return switch (scope) {
            case "done" -> List.of("DONE", "CANCELED");
            case "pending" -> List.of("OPEN");
            // 客户端可能写 in_progress 或 inProgress，小写化后两种都落在这里。
            case "in_progress", "inprogress" -> List.of("IN_PROGRESS");
            default -> List.of("OPEN", "IN_PROGRESS");
        };
    }

    /**
     * 任务中心两档计数(ADR-100)：open = 还没人接手(红：轮到研发动手)，
     * inProgress = 已接手在办(黄：在跑、现在不用我动手)。一条 SQL 分桶。
     */
    @Transactional(readOnly = true)
    public RdTaskCounts counts() {
        RdTaskCounts counts = jdbc.queryForObject("""
                SELECT COUNT(*) FILTER (WHERE status = 'OPEN'),
                       COUNT(*) FILTER (WHERE status = 'IN_PROGRESS')
                FROM rd_tasks
                WHERE is_deleted = false AND status IN ('OPEN','IN_PROGRESS')
                """, (rs, rowNum) -> new RdTaskCounts(rs.getLong(1), rs.getLong(2)));
        return counts == null ? new RdTaskCounts(0, 0) : counts;
    }

    /** 研发任务中心计数：待处理 + 进行中；total 是旧「待完成」口径，两者之和。 */
    public record RdTaskCounts(long open, long inProgress) {
        public long total() {
            return open + inProgress;
        }
    }

    @Transactional(readOnly = true)
    public RdTaskRow get(UUID id) {
        List<RdTaskRow> rows = jdbc.query(SELECT_COLUMNS + " WHERE t.id = ? AND t.is_deleted = false",
                (rs, rowNum) -> mapRow(rs), id);
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "任务不存在");
        return rows.get(0);
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

    /**
     * 某货品「正在等研发完善 BOM」的等待名单（员工档案 id + 他当时被挡住的来源单据），供研发保存 BOM 后
     * 逐个通知并直达来源单据。来源：rd_task_forwarders（JOIN 未完成任务过滤），同一人取最早登记的那条来源；
     * 名单为空时兜底取任务自身 reporter 与任务来源。
     */
    @Transactional(readOnly = true)
    public List<BomTaskWaiter> openBomTaskWaiters(UUID goodsId) {
        List<BomTaskWaiter> waiters = jdbc.query("""
                SELECT DISTINCT ON (f.reporter_employee_id)
                       f.reporter_employee_id, f.source_doc_type, f.source_doc_id
                FROM rd_task_forwarders f
                JOIN rd_tasks t ON t.id = f.rd_task_id
                WHERE t.is_deleted = false AND t.category = 'BOM'
                  AND t.status IN ('OPEN','IN_PROGRESS') AND t.goods_id = ?
                ORDER BY f.reporter_employee_id, f.created_at, f.id
                """, (rs, rowNum) -> new BomTaskWaiter(
                        rs.getObject("reporter_employee_id", UUID.class),
                        rs.getString("source_doc_type"),
                        rs.getObject("source_doc_id", UUID.class)), goodsId);
        if (!waiters.isEmpty()) {
            return waiters;
        }
        return jdbc.query("""
                SELECT DISTINCT ON (reporter_employee_id)
                       reporter_employee_id, source_doc_type, source_doc_id
                FROM rd_tasks
                WHERE is_deleted = false AND category = 'BOM'
                  AND status IN ('OPEN','IN_PROGRESS') AND goods_id = ?
                ORDER BY reporter_employee_id, created_at, id
                """, (rs, rowNum) -> new BomTaskWaiter(
                        rs.getObject("reporter_employee_id", UUID.class),
                        rs.getString("source_doc_type"),
                        rs.getObject("source_doc_id", UUID.class)), goodsId);
    }

    /** 等研发完善 BOM 的人与他被挡住的来源单据(来源类型见 RdBomGapPort.SOURCE_*，可能为空)。 */
    public record BomTaskWaiter(UUID employeeId, String sourceDocType, UUID sourceDocId) {}

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
                actions,
                rs.getString("color_name"));
    }

    private ApiException concurrentChange() {
        return new ApiException(ErrorCode.CONFLICT, "任务状态已变更，请刷新后重试");
    }
}
