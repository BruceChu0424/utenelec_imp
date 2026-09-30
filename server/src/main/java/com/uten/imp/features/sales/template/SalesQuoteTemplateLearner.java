package com.uten.imp.features.sales.template;

import com.uten.imp.features.sales.intake.SalesIntakeUsedEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.core.Ordered;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** Runs after committed document save and before master learning consumes the server intake result. */
@Component
public class SalesQuoteTemplateLearner {
    private static final Logger log = LoggerFactory.getLogger(SalesQuoteTemplateLearner.class);
    private final SalesQuoteTemplateStore store;
    public SalesQuoteTemplateLearner(SalesQuoteTemplateStore store) { this.store = store; }
    private com.uten.imp.application.port.SalesLearningReceiptPort receipts;
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    void setLearningReceipts(com.uten.imp.application.port.SalesLearningReceiptPort receipts) { this.receipts = receipts; }
    @EventListener
    public void onIntakeUsed(SalesIntakeUsedEvent event) {
        if (event == null || event.jobId() == null || event.userId() == null) return;
        Runnable learn = () -> {
            if (receipts != null && event.learningReceiptId() != null) {
                receipts.run(event.learningReceiptId(), "TEMPLATE", event.jobId(), () -> {
                    store.adopt(event);
                    return store.learnedFrom(event) ? com.uten.imp.application.port.SalesLearningReceiptPort.StepResult.done()
                            : com.uten.imp.application.port.SalesLearningReceiptPort.StepResult.skippedResult();
                });
                return;
            }
            try { store.adopt(event); }
            catch (RuntimeException failure) { log.warn("quote template learning skipped job={} cause={}", event.jobId(), failure.getClass().getSimpleName()); }
        };
        if (!TransactionSynchronizationManager.isSynchronizationActive()) { learn.run(); return; }
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override public int getOrder() { return Ordered.HIGHEST_PRECEDENCE + 1; }
            @Override public void afterCommit() { learn.run(); }
        });
    }
}
