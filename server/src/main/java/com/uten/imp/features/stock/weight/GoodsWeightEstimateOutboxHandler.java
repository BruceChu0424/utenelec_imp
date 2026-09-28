package com.uten.imp.features.stock.weight;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.BusinessOutboxDomainHandler;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * 称重观测变化 (登记/红冲) 后重算该货品的单重: 由业务事件派发任务在它自己的事务里调用,
 * 与过账事务分开, 过账不等重算, 同一单据的后续行也不会用到本单据刚登记的观测。
 * 重算是整体幂等的, 同一货品多条事件重复处理无副作用。
 */
@Component
@RequiredArgsConstructor
public class GoodsWeightEstimateOutboxHandler implements BusinessOutboxDomainHandler {

    private final GoodsWeightEstimateService estimates;

    @Override
    public boolean supports(String eventType) {
        return GoodsWeightObservationService.EVENT_OBSERVATION_CHANGED.equals(eventType);
    }

    @Override
    public void handle(UUID outboxEventId, String eventType, UUID aggregateId, JsonNode payload, UUID createdBy) {
        if (aggregateId == null) {
            throw new IllegalArgumentException("weight observation event has no goods id");
        }
        estimates.recompute(aggregateId);
    }
}
