package com.uten.imp.features.sales.intake;

import com.uten.imp.application.port.AiJobUsagePort;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.core.Ordered;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;

/**
 * 保存后学习客户文件版式(ADR-134): 报价/订货保存时发布 {@link SalesIntakeUsedEvent}, 这里按服务端保存的识别结果登记
 * 「表头指纹 → 列角色」, 下次同版式文件直接取列、不再调用 AI。
 *
 * <p>全部在保存事务<b>提交之后</b>做, 而且是<b>最先执行</b>的提交后回调({@link Ordered#HIGHEST_PRECEDENCE}):
 * 先在独立的只读事务里读任务结果里的版式({@link AiJobUsagePort#resultFor}, 只有提交人本人能读到, 从不信任请求体),
 * 再在独立事务里写 sales_intake_layouts。主档学习的提交后回调排在最后({@link Ordered#LOWEST_PRECEDENCE}),
 * 它最后一步 {@link AiJobUsagePort#markUsed} 会在同一条语句里清空结果(公共任务框架没有采用后的保留期),
 * 所以本回调必须排在它前面(先读后标记, ADR-133)。保存事务里什么都不读不写, 读结果出错也不会把保存事务标成
 * 只能回滚。保存回滚则什么都不做; 任何失败只记日志, 不影响单据保存。
 */
@Component
class SalesIntakeLayoutLearner {

    private static final Logger log = LoggerFactory.getLogger(SalesIntakeLayoutLearner.class);

    private final AiJobUsagePort usage;
    private final IntakeReferenceData store;
    private final TransactionTemplate readTransaction;

    SalesIntakeLayoutLearner(AiJobUsagePort usage, IntakeReferenceData store, PlatformTransactionManager transactionManager) {
        this.usage = usage;
        this.store = store;
        this.readTransaction = new TransactionTemplate(transactionManager);
        this.readTransaction.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.readTransaction.setReadOnly(true);
    }

    @EventListener
    public void onIntakeUsed(SalesIntakeUsedEvent event) {
        if (event == null || event.jobId() == null || event.userId() == null) {
            return;
        }
        if (!TransactionSynchronizationManager.isSynchronizationActive()) {
            learn(event);
            return;
        }
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public int getOrder() {
                return Ordered.HIGHEST_PRECEDENCE;
            }

            @Override
            public void afterCommit() {
                learn(event);
            }
        });
    }

    /** 读版式并写入; 任何失败只记日志。 */
    void learn(SalesIntakeUsedEvent event) {
        LayoutFacts facts;
        try {
            facts = readTransaction.execute(status -> capture(event));
        } catch (RuntimeException e) {
            log.warn("sales intake layout learning skipped: job={} reason={}", event.jobId(), e.getClass().getSimpleName());
            return;
        }
        if (facts != null) {
            write(event, facts);
        }
    }

    /** 读取任务结果里的版式; 没有结果(不是本人、已清空、不是表格文件)返回 null。 */
    LayoutFacts capture(SalesIntakeUsedEvent event) {
        Optional<Map<String, Object>> result = usage.resultFor(event.jobId(), event.userId());
        return result.map(SalesIntakeLayoutLearner::layoutFacts).orElse(null);
    }

    void write(SalesIntakeUsedEvent event, LayoutFacts facts) {
        try {
            store.upsertLayout(facts.fingerprint(), event.clientId(), facts.headerTexts(), facts.columnRoles(),
                    facts.headerRowOffset());
        } catch (RuntimeException e) {
            log.warn("sales intake layout learning failed: job={} reason={}", event.jobId(), e.getClass().getSimpleName());
        }
    }

    /** 从识别结果里取版式(只有表格文件、且版式来自规则/AI/学习时才有)。 */
    record LayoutFacts(String fingerprint, String headerTexts, Map<String, String> columnRoles, int headerRowOffset) {
    }

    static LayoutFacts layoutFacts(Map<String, Object> result) {
        if (!(result.get("extraction") instanceof Map<?, ?> extraction)) {
            return null;
        }
        Object source = extraction.get("layoutSource");
        if (!(source instanceof String s) || !(s.equals(IntakeLayout.SOURCE_RULES) || s.equals(IntakeLayout.SOURCE_AI)
                || s.equals(IntakeLayout.SOURCE_LEARNED))) {
            return null;
        }
        if (!(extraction.get("layoutFingerprint") instanceof String fingerprint)
                || !(extraction.get("headerTexts") instanceof String headerTexts)
                || !(extraction.get("columnRoles") instanceof Map<?, ?> roles)) {
            return null;
        }
        Map<String, String> columnRoles = new LinkedHashMap<>();
        for (Map.Entry<?, ?> e : roles.entrySet()) {
            if (e.getKey() instanceof String k && e.getValue() instanceof String v) {
                columnRoles.put(k, v);
            }
        }
        int offset = (int) headerTexts.chars().filter(c -> c == '\n').count();
        return new LayoutFacts(fingerprint, headerTexts, columnRoles, offset);
    }
}
