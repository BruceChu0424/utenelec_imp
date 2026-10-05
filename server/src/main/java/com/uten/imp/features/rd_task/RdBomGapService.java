package com.uten.imp.features.rd_task;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.RdBomGapPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.extern.slf4j.Slf4j;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.Collection;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * 委外件缺 BOM 转研发(ADR-143 §二.3, 实现 {@link RdBomGapPort})。
 *
 * <p>每个货品同时只有一条未完成「完善 BOM」任务(唯一索引 {@code uq_rd_tasks_open_bom});
 * 后来发现缺口的人只进等待名单。写入总在独立的短事务里做: 调用方的事务既不会拿研发表的锁,
 * 也不会因为随后抛 409 把研发任务一起回滚。两个人同时登记同一货品时, 后到的一方撞唯一索引,
 * 在新事务里重来一次就会复用先建的那条任务(只有新建时才通知研发)。
 */
@Slf4j
@Service
public class RdBomGapService implements RdBomGapPort {

    /** 新建「完善 BOM」任务事件(→ ChainNoticeService 通知工程研发部)。 */
    public static final String EVENT_FORWARDED = "RD_TASK_FORWARDED";

    private static final int MAX_ATTEMPTS = 3;

    private final JdbcTemplate jdbc;
    private final NamedParameterJdbcTemplate named;
    private final DocNumberService docNumbers;
    private final BusinessEventPublisher events;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final TransactionTemplate requiresNew;

    public RdBomGapService(JdbcTemplate jdbc, DocNumberService docNumbers, BusinessEventPublisher events,
                           SecurityContextCurrentUser currentUser, TxSessionVars tx,
                           PlatformTransactionManager transactionManager) {
        this.jdbc = jdbc;
        this.named = new NamedParameterJdbcTemplate(jdbc);
        this.docNumbers = docNumbers;
        this.events = events;
        this.currentUser = currentUser;
        this.tx = tx;
        this.requiresNew = new TransactionTemplate(transactionManager);
        this.requiresNew.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }

    @Override
    public RdBomGap forwardBomGap(UUID goodsId, String sourceDocType, UUID sourceDocId,
                                  String sourceDocNo, String reasonText) {
        return forwardBomGap(goodsId, sourceDocType, sourceDocId, sourceDocNo, reasonText, null);
    }

    @Override
    public RdBomGap forwardBomGap(UUID goodsId, String sourceDocType, UUID sourceDocId,
                                  String sourceDocNo, String reasonText, UUID reporterEmployeeId) {
        Objects.requireNonNull(goodsId, "goodsId");
        UUID reporter = reporterEmployeeId != null ? reporterEmployeeId : currentUser.requireEmployeeId();
        UUID actor = currentUser.id().orElse(null);
        return forwardWithRetry(goodsId, sourceDocType, sourceDocId, sourceDocNo, reasonText, reporter, actor);
    }

    @Override
    public void forwardBomGapsAfterCommit(Collection<UUID> goodsIds, String sourceDocType, UUID sourceDocId,
                                          String sourceDocNo, String reasonText, UUID reporterEmployeeId) {
        if (goodsIds == null || goodsIds.isEmpty()
                || !TransactionSynchronizationManager.isSynchronizationActive()) {
            return;
        }
        List<UUID> goods = goodsIds.stream().filter(Objects::nonNull).distinct().toList();
        UUID reporter = reporterEmployeeId != null ? reporterEmployeeId : currentUser.employeeId().orElse(null);
        if (goods.isEmpty() || reporter == null) return;
        UUID actor = currentUser.id().orElse(null);
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                for (UUID goodsId : goods) {
                    try {
                        forwardWithRetry(goodsId, sourceDocType, sourceDocId, sourceDocNo, reasonText, reporter, actor);
                    } catch (RuntimeException failure) {
                        // 原事务已提交: 登记失败不影响它, 下一次刷新会再登记一次。
                        log.warn("BOM gap forward after commit failed: goods={} source={} {}: {}",
                                goodsId, sourceDocType, sourceDocNo, failure.toString());
                    }
                }
            }
        });
    }

    @Override
    public Set<UUID> goodsAwaitingForward(Collection<UUID> goodsIds, UUID reporterEmployeeId) {
        Set<UUID> ids = nonNullSet(goodsIds);
        if (ids.isEmpty()) return Set.of();
        if (reporterEmployeeId == null) return ids;
        Set<UUID> registered = new HashSet<>(named.queryForList("""
                SELECT DISTINCT t.goods_id
                FROM rd_tasks t
                JOIN rd_task_forwarders f ON f.rd_task_id = t.id
                WHERE t.goods_id IN (:goodsIds)
                  AND t.category = 'BOM' AND t.status IN ('OPEN','IN_PROGRESS') AND t.is_deleted = FALSE
                  AND f.reporter_employee_id = :reporter
                """, new MapSqlParameterSource()
                        .addValue("goodsIds", ids)
                        .addValue("reporter", reporterEmployeeId), UUID.class));
        Set<UUID> result = new LinkedHashSet<>(ids);
        result.removeAll(registered);
        return result;
    }

    @Override
    public Optional<RdBomGap> openBomGap(UUID goodsId) {
        if (goodsId == null) return Optional.empty();
        return jdbc.query(OPEN_TASK_SQL, (rs, rowNum) -> new RdBomGap(
                rs.getObject("id", UUID.class), rs.getString("task_no"), false), goodsId).stream().findFirst();
    }

    @Override
    public Map<UUID, String> openBomTaskNos(Collection<UUID> goodsIds) {
        Set<UUID> ids = nonNullSet(goodsIds);
        if (ids.isEmpty()) return Map.of();
        Map<UUID, String> result = new HashMap<>();
        for (Map.Entry<UUID, String> row : named.query("""
                SELECT goods_id, task_no
                FROM rd_tasks
                WHERE goods_id IN (:goodsIds)
                  AND category = 'BOM' AND status IN ('OPEN','IN_PROGRESS') AND is_deleted = FALSE
                ORDER BY goods_id, created_at DESC
                """, new MapSqlParameterSource("goodsIds", ids),
                (rs, rowNum) -> Map.entry(rs.getObject("goods_id", UUID.class), rs.getString("task_no")))) {
            result.putIfAbsent(row.getKey(), row.getValue());
        }
        return Map.copyOf(result);
    }

    private static final String OPEN_TASK_SQL = """
            SELECT id, task_no
            FROM rd_tasks
            WHERE goods_id = ?
              AND category = 'BOM' AND status IN ('OPEN','IN_PROGRESS') AND is_deleted = FALSE
            ORDER BY created_at DESC
            LIMIT 1
            """;

    /** 撞唯一索引说明另一事务刚建了同一货品的任务: 在新事务里重来就会复用它。 */
    private RdBomGap forwardWithRetry(UUID goodsId, String sourceDocType, UUID sourceDocId, String sourceDocNo,
                                      String reasonText, UUID reporter, UUID actor) {
        for (int attempt = 1; ; attempt++) {
            try {
                return requiresNew.execute(status -> forwardInTransaction(
                        goodsId, sourceDocType, sourceDocId, sourceDocNo, reasonText, reporter, actor));
            } catch (DataIntegrityViolationException concurrent) {
                if (attempt >= MAX_ATTEMPTS) {
                    throw new ApiException(ErrorCode.CONFLICT, "通知研发完善 BOM 时有人同时在操作，请稍后重试");
                }
            }
        }
    }

    private RdBomGap forwardInTransaction(UUID goodsId, String sourceDocType, UUID sourceDocId, String sourceDocNo,
                                          String reasonText, UUID reporter, UUID actor) {
        tx.bind();
        RdBomGap gap = jdbc.query(OPEN_TASK_SQL, (rs, rowNum) -> new RdBomGap(
                rs.getObject("id", UUID.class), rs.getString("task_no"), false), goodsId).stream()
                .findFirst().orElse(null);
        if (gap == null) {
            UUID taskId = UUID.randomUUID();
            String taskNo = docNumbers.nextNumber(DocNumberPrefix.RD_TASK);
            int inserted = jdbc.update("""
                    INSERT INTO rd_tasks (id, task_no, title, description, category, status, priority,
                        goods_id, source_doc_type, source_doc_id, source_doc_no,
                        reporter_employee_id, row_version, created_by, updated_by)
                    SELECT ?, ?,
                           LEFT('完善委外件 BOM(直属物料)：' || COALESCE(g.name, '')
                                || CASE WHEN COALESCE(g.code, '') = '' THEN '' ELSE '(' || g.code || ')' END, 200),
                           ?, 'BOM', 'OPEN', 'NORMAL', g.id, ?, ?, ?, ?, 1, ?, ?
                    FROM goods g
                    WHERE g.id = ?
                    """,
                    taskId, taskNo, reasonText, sourceDocType, sourceDocId, truncate(sourceDocNo, 64),
                    reporter, actor, actor, goodsId);
            if (inserted != 1) {
                throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在，无法通知研发完善 BOM");
            }
            gap = new RdBomGap(taskId, taskNo, true);
            events.publish(EVENT_FORWARDED, "RD_TASK", taskId, Map.of(
                    "goodsId", goodsId.toString(),
                    "reporterEmployeeId", reporter.toString()));
        }
        // 当前等待人进名单(同一人同一任务只一行); 研发保存 BOM 后按名单逐个通知。
        jdbc.update("""
                INSERT INTO rd_task_forwarders (rd_task_id, reporter_employee_id,
                    source_doc_type, source_doc_id, source_doc_no, created_by)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (rd_task_id, reporter_employee_id) DO NOTHING
                """, gap.taskId(), reporter, sourceDocType, sourceDocId, truncate(sourceDocNo, 64), actor);
        return gap;
    }

    private static Set<UUID> nonNullSet(Collection<UUID> values) {
        if (values == null) return Set.of();
        Set<UUID> result = new LinkedHashSet<>();
        for (UUID value : values) if (value != null) result.add(value);
        return result;
    }

    private static String truncate(String value, int max) {
        if (value == null) return null;
        return value.length() <= max ? value : value.substring(0, max);
    }
}
