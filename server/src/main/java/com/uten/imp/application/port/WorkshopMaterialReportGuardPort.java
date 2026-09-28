package com.uten.imp.application.port;

import java.time.LocalDate;
import java.util.Collection;
import java.util.UUID;

/**
 * 报工截止守卫端口 (ADR-131 §5.6、§10; ADR-017 跨 feature 只经 Port)。
 *
 * <p>段绑定了某个车间内料仓时, 报工日期落在该仓已结算期间的, 新建、审核、红冲一律拒绝。生产日报在
 * 自己的事务里、写明细之前调用一次; 实现方预读涉及的期间 (段绑定的内料仓 + 该日期所在期间), 按期间 id
 * 排序加共享锁, 与结算事务的排他锁互斥, 保证结算期间不会有报工插进已结算的日期。
 * 实现方在 {@code features.warehouse.materialbin}, 运行在调用方事务里。
 */
public interface WorkshopMaterialReportGuardPort {

    /** 调用时机。 */
    enum Operation {
        /** 新建或修改草稿 (用请求里的日期与明细段)。 */
        SAVE,
        /** 审核; 预读到被「未审报工」拦住的期间时, 本事务提交后自动再试一次结算。 */
        APPROVE,
        /** 红冲。 */
        REVERSE
    }

    /**
     * 锁住相关期间并检查日期; 已结算时抛冲突, 文案给员工看 (新建提示改填哪天, 审核/红冲提示找谁撤销结算)。
     *
     * @param reportId   日报 id; 新建时为空
     * @param billDate   日报表头业务日期
     * @param segmentIds 明细涉及的任务段; 为空时直接返回
     */
    void lockAndCheck(UUID reportId, LocalDate billDate, Collection<UUID> segmentIds, Operation op);
}
