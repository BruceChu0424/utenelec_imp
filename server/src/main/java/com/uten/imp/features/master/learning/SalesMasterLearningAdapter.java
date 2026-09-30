package com.uten.imp.features.master.learning;

import com.uten.imp.application.port.AiJobUsagePort;
import com.uten.imp.application.port.SalesMasterLearningPort;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.core.Ordered;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 销售单据保存后的主档学习入口(ADR-134, 实现 {@link SalesMasterLearningPort})。
 *
 * <p>两段式:
 * <ol>
 *   <li><b>保存事务内</b>(本方法): 只做校验, 勾选的客户字段不合法直接抛 422, 此时学习还没写任何东西,
 *       保存整体回滚; 通过后登记一个提交后回调。</li>
 *   <li><b>保存提交后</b>(回调, 同一请求线程): 在新的只读事务里取服务端保存的识别结果
 *       ({@link AiJobUsagePort#resultFor}), 算出学习计划, 再在<b>独立事务</b>
 *       ({@link SalesMasterLearningApplier#apply}) 里写对照、英文名称与客户资料; 最后在又一个独立事务里
 *       标记识别结果已使用并清空结果({@link AiJobUsagePort#markUsed})。任何一步失败只写告警日志,
 *       日志不含客户文件内容, 已提交的保存不受影响。</li>
 * </ol>
 *
 * <p>回调顺序: 本回调的顺序是 {@link Ordered#LOWEST_PRECEDENCE}, 且最后一步会清空识别结果。
 * 其它需要在提交后读取同一识别结果的回调(例如识别模块登记客户文件版式)必须排在它前面
 * (更小的 order, 例如 {@code @Order(Ordered.HIGHEST_PRECEDENCE)}), 或在保存事务内先读好。
 *
 * <p>AI 平台是可选依赖: 没有 {@link AiJobUsagePort} 时按「没有识别结果」学习(只学用户明确选择的手打原文,
 * 不学全局对照与英文名称)。
 */
@Slf4j
@Service
public class SalesMasterLearningAdapter implements SalesMasterLearningPort {

    private final SalesMasterLearningApplier applier;
    private final ObjectProvider<AiJobUsagePort> jobUsage;
    private final SecurityContextCurrentUser currentUser;
    private final TransactionTemplate readOnlyNew;
    private final TransactionTemplate writeNew;
    private com.uten.imp.application.port.SalesLearningReceiptPort receipts;
    @org.springframework.beans.factory.annotation.Autowired
    void setLearningReceipts(com.uten.imp.application.port.SalesLearningReceiptPort receipts) { this.receipts = receipts; }

    public SalesMasterLearningAdapter(SalesMasterLearningApplier applier,
                                      ObjectProvider<AiJobUsagePort> jobUsage,
                                      SecurityContextCurrentUser currentUser,
                                      PlatformTransactionManager transactionManager) {
        this.applier = applier;
        this.jobUsage = jobUsage;
        this.currentUser = currentUser;
        this.readOnlyNew = new TransactionTemplate(transactionManager);
        this.readOnlyNew.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.readOnlyNew.setReadOnly(true);
        this.writeNew = new TransactionTemplate(transactionManager);
        this.writeNew.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }

    @Override
    public void learnAfterCommit(SalesLearningRequest request) {
        Objects.requireNonNull(request, "request");
        String docType = normalizeDocType(request.docType());
        // 保存事务内先校验: 不合法抛 422(此时学习尚未写任何东西, 保存整体回滚)。
        Map<String, String> clientFields = request.clientId() == null
                ? Map.of()
                : ClientDocumentFields.normalizeAndValidate(request.clientFields());
        if (request.lines().isEmpty() && clientFields.isEmpty() && request.intakeJobId() == null
                && !hasDocumentLearning(docType, request.docId())) {
            return;
        }
        UUID principalId = currentUser.get().map(AuthUser::getId).orElse(null);
        if (principalId != null && request.actorUserId() != null && !principalId.equals(request.actorUserId())) {
            // 编程错误: 学习的权限按当前登录人判定, 与请求声明的保存人不一致时不学, 也不影响保存。
            log.warn("sales learning skipped: actor mismatch docType={} docId={}", docType, request.docId());
            return;
        }
        UUID actor = request.actorUserId() != null ? request.actorUserId() : principalId;
        SalesLearningRequest command = new SalesLearningRequest(request.docType(),request.docId(),request.clientId(),
                request.actorUserId(),request.actorEmployeeId(),request.lines(),clientFields,request.intakeJobId(),
                request.additionalIntakeJobIds(),request.learningReceiptId());
        if (receipts != null && command.learningReceiptId() != null) receipts.register(command);
        Runnable learning = () -> runAfterCommit(docType, actor, command, clientFields);
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(new AfterCommit(learning));
        } else {
            // 调用方没有事务(不应发生): 保存已经落库, 直接学习。
            learning.run();
        }
    }

    /** Confirmed learning failures remain visible and retryable; results are consumed only after every step completes. */
    void runAfterCommit(String docType, UUID actor, SalesLearningRequest request, Map<String, String> clientFields) {
        AiJobUsagePort usage = jobUsage.getIfAvailable();
        java.util.Set<UUID> consumedJobs = new java.util.LinkedHashSet<>();
        UUID receiptId = receipts == null ? null : request.learningReceiptId();
        if (receiptId == null && request.intakeJobId() != null) consumedJobs.add(request.intakeJobId());
        java.util.function.Supplier<com.uten.imp.application.port.SalesLearningReceiptPort.StepResult> learn = () -> {
            Map<UUID, Map<String, Object>> results = new java.util.LinkedHashMap<>();
            if (usage != null && actor != null) {
                for (UUID jobId : request.intakeJobIds()) {
                    Map<String, Object> result = receiptId == null
                            ? readOnlyNew.execute(status -> usage.resultFor(jobId, actor).orElse(null))
                            : receipts.evidence(receiptId, jobId).orElse(null);
                    if (result == null) continue;
                    IntakeJobLines parsed = IntakeJobLines.parse(result);
                    String prefix = jobId + ":";
                    boolean contributed = jobId.equals(request.intakeJobId()) || request.lines().stream().anyMatch(line ->
                            line.intakeLineKey() != null && line.intakeLineKey().startsWith(prefix)
                                    && parsed.line(line.intakeLineKey().substring(prefix.length())) != null);
                    if (contributed) {
                        results.put(jobId, result); consumedJobs.add(jobId);
                        if (receiptId != null) receipts.rememberEvidence(receiptId, jobId, result);
                    }
                }
            }
            IntakeJobLines jobLines = IntakeJobLines.combine(request.intakeJobId(), results);
            SalesLearningPlanner.Plan plan = SalesLearningPlanner.plan(request, jobLines);
            if (!plan.isEmpty() || !clientFields.isEmpty() || hasDocumentLearning(docType, request.docId())) {
                SalesMasterLearningApplier.Outcome outcome = receiptId == null
                        ? applier.apply(docType, request.docId(), request.clientId(), actor, plan, clientFields)
                        : applier.applyConfirmed(docType, request.docId(), request.clientId(), actor, plan, clientFields, receiptId);
                return new com.uten.imp.application.port.SalesLearningReceiptPort.StepResult(false, Map.of(
                        "aliases", outcome.aliasesWritten(), "retractedAliases", outcome.aliasesRetracted(),
                        "englishNames", outcome.nameEnUpdated(), "clientFields", outcome.clientFieldsApplied().size()));
            }
            return com.uten.imp.application.port.SalesLearningReceiptPort.StepResult.done();
        };
        if (receiptId != null) {
            receipts.run(receiptId, "MASTER", null, learn);
            if (!receipts.canConsume(receiptId)) return;
            consumedJobs.addAll(receipts.consumableJobs(receiptId));
            receipts.run(receiptId, "CONSUME", null, () -> {
                if (usage != null && actor != null) for (UUID jobId : consumedJobs)
                    writeNew.executeWithoutResult(status -> usage.markUsed(jobId, actor, docType, request.docId()));
                return com.uten.imp.application.port.SalesLearningReceiptPort.StepResult.done();
            });
            return;
        }
        try { learn.get(); }
        catch (RuntimeException failure) {
            log.warn("sales learning failed docType={} docId={} cause={}", docType, request.docId(), failure.getClass().getName());
            return; // Never discard the only trusted source after a failed learning transaction.
        }
        for (UUID jobId : consumedJobs) {
            if (usage == null || actor == null) continue;
            try { writeNew.executeWithoutResult(status -> usage.markUsed(jobId, actor, docType, request.docId())); }
            catch (RuntimeException failure) { log.warn("marking intake job used failed docType={} docId={} jobId={} cause={}",
                    docType, request.docId(), jobId, failure.getClass().getName()); }
        }
    }

    @Override
    public boolean hasDocumentLearning(String docType, UUID docId) { return applier.hasDocumentLearning(normalizeDocType(docType), docId); }

    static String normalizeDocType(String docType) {
        String value = docType == null ? "" : docType.trim().toLowerCase(Locale.ROOT);
        if (!"quote".equals(value) && !"order".equals(value)) {
            throw new IllegalArgumentException("docType must be quote or order");
        }
        return value;
    }

    /** 提交后回调; 排在最后(见类注释)。 */
    private record AfterCommit(Runnable learning) implements TransactionSynchronization {

        @Override
        public int getOrder() {
            return Ordered.LOWEST_PRECEDENCE;
        }

        @Override
        public void afterCommit() {
            learning.run();
        }
    }
}
