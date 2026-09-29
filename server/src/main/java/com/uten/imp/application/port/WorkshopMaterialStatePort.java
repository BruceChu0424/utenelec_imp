package com.uten.imp.application.port;

import java.util.Optional;
import java.util.UUID;

/**
 * 车间内料仓开工状态端口 (ADR-131 §5.4; ADR-017 跨 feature 只经 Port)。
 *
 * <p>生产执行 (开工门、车间任务台) 只问两件事: 这一段现在是哪种用料状态、能不能开工。状态由数据库
 * 函数 {@code fn_segment_bin_material_state} 统一给出, 服务端开工门与数据库开工触发器读同一个口径,
 * 前后自动一致。实现方在 {@code features.warehouse.materialbin}, 运行在调用方事务里, 只读。
 */
public interface WorkshopMaterialStatePort {

    /** 段已有期间料行, 或车间已开启且产品有期间边 / 有效期间料行 / 用料认料: 放行。 */
    String KNOWN = "KNOWN";
    /** 段上有未核清的整批领料货品按单需求, 或产品认料为按工单领料: 走原按单领料门。 */
    String ORDER_ONLY = "ORDER_ONLY";
    /** 车间没开启整批领料, 产品也没有期间边: 原样。 */
    String NO_BIN = "NO_BIN";
    /** 产品有期间边, 但车间没开启整批领料: 拒绝开工。 */
    String NEED_BIN = "NEED_BIN";
    /** 车间已开启, 产品还没认料: 拒绝开工, 开工确认表里认完即放行。 */
    String NEED_CHOICE = "NEED_CHOICE";

    /** 段的用料状态, 取值见本接口常量; 段不存在时为 {@link #NO_BIN}。 */
    String state(UUID segmentId);

    /**
     * {@link #NEED_CHOICE} / {@link #NEED_BIN} 时返回可直接给员工看的中文拦截文案
     * (带产品名、料名、车间名); 其余状态为空。
     */
    Optional<String> startBlockMessage(UUID segmentId);
}
