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

    private com.uten.imp.application.port.SalesLearningReceiptPort receipts;
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    void setLearningReceipts(com.uten.imp.application.port.SalesLearningReceiptPort receipts) { this.receipts = receipts; }

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

    @EventListener
    public void onTemplateAdopted(com.uten.imp.features.sales.template.SalesQuoteTemplateAdoptedEvent adopted) {
        SalesIntakeUsedEvent event = new SalesIntakeUsedEvent(adopted.jobId(), adopted.actorId(), "quote", adopted.quoteId(), adopted.clientId());
        Runnable learn = () -> {
            try {
                LayoutFacts facts = readTransaction.execute(status -> capture(event));
                if (facts != null) store.learnLayoutOnce(event, facts.fingerprint(), facts.headerTexts(), facts.columnRoles(),
                        facts.headerRowOffset(), facts.learned());
            } catch (RuntimeException failure) {
                log.warn("quote template column learning failed job={} reason={}", event.jobId(), failure.getClass().getSimpleName());
            }
        };
        if (!TransactionSynchronizationManager.isSynchronizationActive()) { learn.run(); return; }
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override public void afterCommit() { learn.run(); }
        });
    }

    /** 读版式并写入; 任何失败只记日志。 */
    void learn(SalesIntakeUsedEvent event) {
        if (receipts != null && event.learningReceiptId() != null) {
            receipts.run(event.learningReceiptId(), "LAYOUT", event.jobId(), () -> {
                LayoutFacts captured = readTransaction.execute(status -> capture(event));
                if (captured == null || event.clientId() == null)
                    return com.uten.imp.application.port.SalesLearningReceiptPort.StepResult.skippedResult();
                store.learnLayoutOnce(event, captured.fingerprint(), captured.headerTexts(), captured.columnRoles(),
                        captured.headerRowOffset(), captured.learned());
                return com.uten.imp.application.port.SalesLearningReceiptPort.StepResult.done();
            });
            return;
        }
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
        return result.filter(value -> includesSourceLine(event.sourceLineKeys(), value))
                .map(SalesIntakeLayoutLearner::layoutFacts).orElse(null);
    }

    /** Learning needs a saved source row; legacy internal events remain compatible. */
    private static boolean includesSourceLine(java.util.List<String> keys, Map<String, Object> result) {
        if (keys == null) return true;
        if (keys.isEmpty() || !(result.get("lines") instanceof java.util.List<?> lines)) return false;
        return lines.stream().anyMatch(line -> line instanceof Map<?, ?> values && keys.contains(values.get("key")));
    }

    void write(SalesIntakeUsedEvent event, LayoutFacts facts) {
        try {
            if (facts.learned()) {
                // 用的就是学习到的版式: 不是新证据, 只刷新使用时间(否则同一客户反复保存会把自己的版式推成全局可信)。
                store.touchLayout(facts.fingerprint(), event.clientId());
            } else {
                store.upsertLayout(facts.fingerprint(), event.clientId(), facts.headerTexts(), facts.columnRoles(),
                        facts.headerRowOffset());
            }
        } catch (RuntimeException e) {
            log.warn("sales intake layout learning failed: job={} reason={}", event.jobId(), e.getClass().getSimpleName());
        }
    }

    /** 从识别结果里取版式(只有表格文件、且版式来自规则/AI/学习时才有); {@code learned} = 版式来自学习。 */
    record LayoutFacts(String fingerprint, String headerTexts, Map<String, String> columnRoles, int headerRowOffset,
                       boolean learned) {
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
        return new LayoutFacts(fingerprint, headerTexts, columnRoles, offset, IntakeLayout.SOURCE_LEARNED.equals(s));
    }
}
