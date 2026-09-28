package com.uten.imp.features.warehouse.materialbin.close;

import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCloseRequester;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.TriggerKind;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.DisposableBean;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.task.TaskRejectedException;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 提交后在后台尝试结算 (ADR-131 §5.8; 规格 §2.5)。
 *
 * <p>提交盘点、更正盘点、补录进已盘点的那一期、报工审核时发现期间正被"未审报工"拦着, 都在各自事务里登记;
 * 本事务提交之后才投递到单线程的后台执行器 (不在请求线程里同步结算, 避开网页端写请求 15 秒上限), 回滚则不投递。
 * 同一事务里同一期只投递一次。服务重启丢掉的投递由每 10 分钟的定时补做接上。
 *
 * <p>{@code uten.workshop-material.auto-close.enabled=false} 时只停掉自动触发 (测试用); 员工点的
 * "立即重试"/"重新结算"照常投递。
 */
@Slf4j
@Component
public class WorkshopMaterialCloseTrigger implements WorkshopMaterialCloseRequester, DisposableBean {

    /** 一次请求。 */
    private record Request(UUID periodId, UUID actorUserId, TriggerKind kind) {}

    private final ObjectProvider<WorkshopMaterialCloseService> closes;
    private final ThreadPoolTaskExecutor executor;
    private final Object pendingResource = new Object();

    @Value("${uten.workshop-material.auto-close.enabled:true}")
    private boolean enabled = true;

    public WorkshopMaterialCloseTrigger(ObjectProvider<WorkshopMaterialCloseService> closes) {
        this.closes = closes;
        this.executor = new ThreadPoolTaskExecutor();
        this.executor.setCorePoolSize(1);
        this.executor.setMaxPoolSize(1);
        this.executor.setQueueCapacity(500);
        this.executor.setThreadNamePrefix("workshop-material-close-");
        this.executor.setWaitForTasksToCompleteOnShutdown(false);
        this.executor.initialize();
    }

    @Override
    public void requestAfterCommit(UUID periodId, UUID actorUserId) {
        request(periodId, actorUserId, TriggerKind.AFTER_COUNT);
    }

    /** 登记本事务提交后的一次结算尝试; 没有事务时立即投递。 */
    public void request(UUID periodId, UUID actorUserId, TriggerKind kind) {
        if (periodId == null || actorUserId == null) return;
        TriggerKind resolved = kind == null ? TriggerKind.AFTER_COUNT : kind;
        if (resolved != TriggerKind.MANUAL && !enabled) return;
        Request request = new Request(periodId, actorUserId, resolved);
        if (!TransactionSynchronizationManager.isSynchronizationActive()) {
            dispatch(request);
            return;
        }
        Pending pending = (Pending) TransactionSynchronizationManager.getResource(pendingResource);
        if (pending == null) {
            pending = new Pending();
            TransactionSynchronizationManager.bindResource(pendingResource, pending);
            TransactionSynchronizationManager.registerSynchronization(pending);
        }
        pending.add(request);
    }

    private void dispatch(Request request) {
        try {
            executor.execute(() -> {
                try {
                    WorkshopMaterialCloseService service = closes.getIfAvailable();
                    if (service != null) service.attempt(request.periodId(), request.kind(), request.actorUserId());
                } catch (RuntimeException error) {
                    log.warn("车间内料仓后台结算未完成, 期间 {}, 错误类型 {}", request.periodId(),
                            error.getClass().getSimpleName());
                }
            });
        } catch (TaskRejectedException rejected) {
            log.warn("车间内料仓后台结算排队已满, 期间 {} 由定时补做接上", request.periodId());
        }
    }

    @Override
    public void destroy() {
        executor.shutdown();
    }

    /** 本事务登记的结算请求; 提交后按登记顺序投递, 同一期"立即重试"优先。 */
    private final class Pending implements TransactionSynchronization {
        private final Map<UUID, Request> requests = new LinkedHashMap<>();

        void add(Request request) {
            Request existing = requests.get(request.periodId());
            if (existing == null || request.kind() == TriggerKind.MANUAL) {
                requests.put(request.periodId(), request);
            }
        }

        @Override
        public void suspend() {
            if (TransactionSynchronizationManager.getResource(pendingResource) == this) {
                TransactionSynchronizationManager.unbindResource(pendingResource);
            }
        }

        @Override
        public void resume() {
            TransactionSynchronizationManager.bindResource(pendingResource, this);
        }

        @Override
        public void afterCommit() {
            for (Request request : List.copyOf(requests.values())) dispatch(request);
        }

        @Override
        public void afterCompletion(int status) {
            if (TransactionSynchronizationManager.getResource(pendingResource) == this) {
                TransactionSynchronizationManager.unbindResource(pendingResource);
            }
            requests.clear();
        }
    }
}
