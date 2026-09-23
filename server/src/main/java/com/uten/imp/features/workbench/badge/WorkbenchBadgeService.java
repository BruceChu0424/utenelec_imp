package com.uten.imp.features.workbench.badge;

import com.uten.imp.application.port.WorkbenchBadgeReadPort;
import com.uten.imp.application.port.WorkbenchBadgeSources;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import lombok.extern.slf4j.Slf4j;
import org.hibernate.Session;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.Connection;
import java.sql.Savepoint;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.EnumMap;
import java.util.EnumSet;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.function.Supplier;

/**
 * 工作台徽章汇总(ADR-108): 在**一个只读事务**里按当前主体把全部登记来源各读一次,
 * 再按 {@link WorkbenchBadgeCatalog} 算出入口 / 容器 / 总数。
 *
 * <p>取代前端约 40 个各自 60s 轮询的计数端点: 一次往返、一个连接、一条请求审计(已登记为
 * 自动请求噪声)。每个来源用 JDBC 保存点隔离——某个来源出错只让它相关的入口进
 * {@code staleEntries}(前端保留上一次的数), 不连累其它入口; 无权访问的来源直接不出现。
 * 事务结尾一律回滚(只读, 回滚与提交等价), 来源内部把事务标成只可回滚也不会报错。
 *
 * <p>同时实现 {@link WorkbenchBadgeReadPort}: 工作台「今日概览」的本部门待办只算自己要的
 * 几个入口(只读它们引用的来源), 数字与红徽章同一口径(permissions-08)。
 */
@Slf4j
@Service
public class WorkbenchBadgeService implements WorkbenchBadgeReadPort {

    private final List<WorkbenchBadgeSources.Source> sources;
    private final TransactionTemplate readOnlyTransaction;

    @PersistenceContext
    private EntityManager entityManager;

    public WorkbenchBadgeService(
            List<WorkbenchBadgeSources> contributors,
            PlatformTransactionManager transactionManager) {
        List<WorkbenchBadgeSources.Source> all = new ArrayList<>();
        Set<String> keys = new HashSet<>();
        for (WorkbenchBadgeSources contributor : contributors) {
            for (WorkbenchBadgeSources.Source source : contributor.sources()) {
                if (!keys.add(source.key())) {
                    throw new IllegalStateException("徽章来源键重复登记: " + source.key());
                }
                all.add(source);
            }
        }
        all.sort(Comparator.comparing(WorkbenchBadgeSources.Source::key));
        for (WorkbenchBadgeCatalog entry : WorkbenchBadgeCatalog.values()) {
            for (String fact : factsOf(entry)) {
                if (!keys.contains(WorkbenchBadgeCatalog.sourceOf(fact))) {
                    throw new IllegalStateException(
                            "徽章入口 " + entry.name() + " 引用了未登记的来源: " + fact);
                }
            }
        }
        this.sources = List.copyOf(all);
        TransactionTemplate template = new TransactionTemplate(transactionManager);
        template.setReadOnly(true);
        template.setName("workbench-badges");
        this.readOnlyTransaction = template;
    }

    /** 当前主体的徽章汇总(全部来源、全部入口)。 */
    public WorkbenchBadgeSummary summary() {
        return readOnly(() -> compute(sources, EnumSet.allOf(WorkbenchBadgeCatalog.class)));
    }

    /** 只算指定入口: 只读它们引用的来源, 口径与 {@link #summary()} 相同。 */
    @Override
    public Entries entries(Set<String> entryNames) {
        Set<WorkbenchBadgeCatalog> wanted = EnumSet.noneOf(WorkbenchBadgeCatalog.class);
        for (String name : entryNames) {
            wanted.add(WorkbenchBadgeCatalog.valueOf(name));
        }
        if (wanted.isEmpty()) return Entries.NONE;
        Set<String> keys = new HashSet<>();
        for (WorkbenchBadgeCatalog entry : wanted) {
            for (String fact : factsOf(entry)) keys.add(WorkbenchBadgeCatalog.sourceOf(fact));
        }
        List<WorkbenchBadgeSources.Source> subset = sources.stream()
                .filter(source -> keys.contains(source.key()))
                .toList();
        WorkbenchBadgeSummary summary = readOnly(() -> compute(subset, wanted));
        Map<String, Long> todo = new LinkedHashMap<>();
        summary.entries().forEach((name, counts) -> todo.put(name, counts.todo()));
        return new Entries(Map.copyOf(todo), Map.copyOf(summary.facts()),
                Set.copyOf(summary.staleEntries()));
    }

    private WorkbenchBadgeSummary readOnly(Supplier<WorkbenchBadgeSummary> work) {
        return readOnlyTransaction.execute(status -> {
            try {
                return work.get();
            } finally {
                // 只读事务: 回滚与提交等价; 显式标记可避免来源内部的只可回滚标记变成异常。
                status.setRollbackOnly();
            }
        });
    }

    private WorkbenchBadgeSummary compute(
            Collection<WorkbenchBadgeSources.Source> toRead, Set<WorkbenchBadgeCatalog> toEmit) {
        Map<String, Long> facts = new TreeMap<>();
        Set<String> granted = new HashSet<>();
        Set<String> failed = new HashSet<>();
        for (WorkbenchBadgeSources.Source source : toRead) {
            Map<String, Long> values = readIsolated(source, failed);
            if (values == null) continue;
            granted.add(source.key());
            values.forEach((field, value) -> facts.put(source.key() + "." + field, value));
        }

        Map<String, WorkbenchBadgeSummary.Counts> entries = new LinkedHashMap<>();
        List<String> stale = new ArrayList<>();
        Map<WorkbenchBadgeCatalog.Module, WorkbenchBadgeSummary.Counts> moduleSums =
                new EnumMap<>(WorkbenchBadgeCatalog.Module.class);
        for (WorkbenchBadgeCatalog entry : toEmit) {
            Set<String> referenced = new LinkedHashSet<>();
            for (String fact : factsOf(entry)) referenced.add(WorkbenchBadgeCatalog.sourceOf(fact));
            boolean anyGranted = referenced.stream().anyMatch(granted::contains);
            boolean anyFailed = referenced.stream().anyMatch(failed::contains);
            if (!anyGranted && !anyFailed) continue; // 无权访问: 入口不出现
            WorkbenchBadgeSummary.Counts counts = new WorkbenchBadgeSummary.Counts(
                    sum(entry.todoFacts(), facts), sum(entry.inProgressFacts(), facts));
            entries.put(entry.name(), counts);
            if (anyFailed) stale.add(entry.name());
            moduleSums.merge(entry.module(), counts, WorkbenchBadgeSummary.Counts::plus);
        }
        Map<String, WorkbenchBadgeSummary.Counts> modules = new LinkedHashMap<>();
        WorkbenchBadgeSummary.Counts total = WorkbenchBadgeSummary.Counts.ZERO;
        for (var module : moduleSums.entrySet()) {
            modules.put(module.getKey().name(), module.getValue());
            total = total.plus(module.getValue());
        }
        return new WorkbenchBadgeSummary(
                Instant.now(), entries, modules, total, facts, List.copyOf(stale),
                failed.stream().sorted().toList());
    }

    /**
     * 在保存点内读一个来源: 成功返回字段 → 数; 无权访问返回 null(不记失败);
     * 其它异常回滚到保存点、记入 failed 并返回 null。
     */
    private Map<String, Long> readIsolated(WorkbenchBadgeSources.Source source, Set<String> failed) {
        Session session = entityManager.unwrap(Session.class);
        Savepoint savepoint = session.doReturningWork(Connection::setSavepoint);
        try {
            Map<String, Long> values = source.reader().get();
            session.doWork(connection -> connection.releaseSavepoint(savepoint));
            return values == null ? Map.of() : values;
        } catch (AccessDeniedException denied) {
            rollbackTo(session, savepoint);
            return null;
        } catch (ApiException business) {
            rollbackTo(session, savepoint);
            if (business.getCode() == ErrorCode.FORBIDDEN || business.getCode() == ErrorCode.UNAUTHORIZED) {
                return null;
            }
            failed.add(source.key());
            log.warn("工作台徽章来源 {} 本次未算出: {}", source.key(), business.getCode());
            return null;
        } catch (RuntimeException failure) {
            rollbackTo(session, savepoint);
            failed.add(source.key());
            log.warn("工作台徽章来源 {} 本次未算出: {}", source.key(), failure.getClass().getSimpleName());
            return null;
        }
    }

    private void rollbackTo(Session session, Savepoint savepoint) {
        session.doWork(connection -> connection.rollback(savepoint));
        // 失败的查询可能留下半截实体状态; 只读汇总不持有任何待写实体, 清掉即可。
        entityManager.clear();
    }

    private static long sum(List<String> keys, Map<String, Long> facts) {
        long total = 0;
        for (String key : keys) {
            if (key.endsWith(".*")) {
                String prefix = key.substring(0, key.length() - 1);
                for (var fact : facts.entrySet()) {
                    if (fact.getKey().startsWith(prefix)) total += fact.getValue();
                }
            } else {
                total += facts.getOrDefault(key, 0L);
            }
        }
        return total;
    }

    private static List<String> factsOf(WorkbenchBadgeCatalog entry) {
        List<String> all = new ArrayList<>(entry.todoFacts());
        all.addAll(entry.inProgressFacts());
        return all;
    }
}
