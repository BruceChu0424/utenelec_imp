package com.uten.imp.application.port;

import java.util.Collection;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * 委外件缺 BOM(没有可发外的直属物料)转工程研发部完善(ADR-143 §二.3)。实现在研发任务模块。
 *
 * <p>同一货品同时只有一条未完成的「完善 BOM」研发任务(库内唯一索引 {@code uq_rd_tasks_open_bom});
 * 后来发现同一缺口的人只加进等待名单({@code rd_task_forwarders}), 研发保存 BOM 后逐个通知。
 * 只有任务新建时才通知研发(outbox {@code RD_TASK_FORWARDED}), 不重复打扰。
 *
 * <p>「缺 BOM」的唯一判定是 {@code fn_subcontract_draw_edges(goods)} 没有任何行; 本端口不判定,
 * 只登记调用方已经判定的缺口。
 */
public interface RdBomGapPort {

    /** 研发任务来源(rd_tasks.source_doc_type / rd_task_forwarders.source_doc_type)。 */
    String SOURCE_MATERIAL_ANALYSIS = "PRODUCTION_MATERIAL_ANALYSIS";
    String SOURCE_SUBCONTRACT_ORDER = "SUBCONTRACT_ORDER";
    String SOURCE_SUBCONTRACT_APPLICATION = "SUBCONTRACT_APPLICATION";
    /** 旧/手工生产计划确认执行计划包时按缺口生成委外申请(不经物料分析)。 */
    String SOURCE_PRODUCTION_PLAN = "PRODUCTION_PLAN";

    /** 一条未完成的「完善 BOM」研发任务; {@code created} = 这次调用新建的(此时才通知研发)。 */
    record RdBomGap(UUID taskId, String taskNo, boolean created) {
    }

    /**
     * 登记缺口并<b>立即在独立事务(REQUIRES_NEW)里提交</b>: 调用方随后抛 409 回滚自己的事务,
     * 研发任务与等待名单照样留下。等待人 = 当前登录员工。并发登记同一货品时复用先建的那条任务。
     */
    RdBomGap forwardBomGap(UUID goodsId, String sourceDocType, UUID sourceDocId,
                           String sourceDocNo, String reasonText);

    /** 同上; 等待人指定为 {@code reporterEmployeeId}(为空时取当前登录员工), 例如财务批准兜底时登记订货单制单人。 */
    RdBomGap forwardBomGap(UUID goodsId, String sourceDocType, UUID sourceDocId,
                           String sourceDocNo, String reasonText, UUID reporterEmployeeId);

    /**
     * 当前事务<b>提交之后</b>再逐个货品登记(每个货品一个独立短事务, 失败只记日志, 互不影响);
     * 当前事务回滚则什么都不做。物料分析新建 / 刷新发现缺 BOM 时用: 调用方事务里不拿研发表的锁,
     * 同一事务后面再走「立即登记」也不会自己等自己。不在事务里调用时不登记。
     */
    void forwardBomGapsAfterCommit(Collection<UUID> goodsIds, String sourceDocType, UUID sourceDocId,
                                   String sourceDocNo, String reasonText, UUID reporterEmployeeId);

    /** 这些货品里, 等待人还没登记在未完成「完善 BOM」任务上的那部分(只读, 用来跳过重复登记)。 */
    Set<UUID> goodsAwaitingForward(Collection<UUID> goodsIds, UUID reporterEmployeeId);

    /** 货品当前未完成的「完善 BOM」研发任务(只读)。 */
    Optional<RdBomGap> openBomGap(UUID goodsId);

    /** 批量只读: 货品 → 未完成「完善 BOM」研发任务编号; 没有未完成任务的货品不在结果里。 */
    Map<UUID, String> openBomTaskNos(Collection<UUID> goodsIds);

    /**
     * 拒绝文案(计划、委外订货、领料计划共用一处措辞)。[goodsLabels] 是「名称(编号)」;
     * [analysisRefreshHint] 为真时补一句研发保存后物料分析会自动更新。
     */
    static String subcontractBomMissingMessage(Collection<String> goodsLabels, boolean analysisRefreshHint) {
        String names = String.join("、", goodsLabels);
        return "委外件 " + names + " 还没有维护 BOM(直属物料)，已通知研发完善"
                + (analysisRefreshHint ? "，研发保存后物料分析会自动更新" : "");
    }

    /** 货品显示名「名称(编号)」; 编号为空时只写名称。 */
    static String goodsLabel(String name, String code) {
        String safeName = name == null ? "" : name.strip();
        String safeCode = code == null ? "" : code.strip();
        if (safeCode.isEmpty()) return safeName;
        return safeName.isEmpty() ? safeCode : safeName + "(" + safeCode + ")";
    }
}
