package com.uten.imp.application.port;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 销售单据保存后的主档学习出口(ADR-134; 实现在 features/master/learning)。
 *
 * <p>只学基础资料: 客户货品对照(型号/品名)、货品英文名称、客户资料空缺字段; 从不学习或修改价格。
 * 学习内容以服务端保存的 AI 任务结果({@link AiJobUsagePort#resultFor})为准, 用 {@code intakeLineKey} 对行;
 * 用户自己手打的文件型号/品名只学成该客户的对照, 不学全局对照, 也不写货品英文名。
 */
public interface SalesMasterLearningPort {

    /**
     * 在保存事务<b>内</b>、明细落库之后调用: 先校验勾选的客户字段(长度、邮箱格式等), 不合法直接抛 400
     * (此时尚未写任何东西); 然后登记一个提交后回调, 在独立的 REQUIRES_NEW 事务里执行学习(按货品 id 顺序
     * 处理, 审计操作人绑定为保存人)。学习失败只记日志, 不影响已经提交的保存。
     */
    void learnAfterCommit(SalesLearningRequest request);
    /** Clearing all customer labels must still retract this document's prior evidence. */
    default boolean hasDocumentLearning(String docType, UUID docId) { return false; }

    /**
     * 一次保存的学习请求。
     *
     * @param docType         {@code quote} 或 {@code order}
     * @param docId           单据 id(同一单据重复保存时对照确认次数不重复累加)
     * @param clientId        单据客户
     * @param actorUserId     保存人账号 id
     * @param actorEmployeeId 保存人员工 id
     * @param lines           带客户文件原文的明细
     * @param clientFields    勾选要补进客户资料的字段(键限 nameEn/fullName/linkman/email/phone/mobile/
     *                        address/taxId/website); 没有勾选为空 Map
     * @param intakeJobId     本次保存所用的 AI 识别任务 id; 没有识别为空(此时只学手打原文的客户对照)
     */
    record SalesLearningRequest(String docType, UUID docId, UUID clientId, UUID actorUserId, UUID actorEmployeeId,
                                List<LearnedLine> lines, Map<String, String> clientFields, UUID intakeJobId,
                                List<UUID> additionalIntakeJobIds, UUID learningReceiptId) {
        public SalesLearningRequest(String docType, UUID docId, UUID clientId, UUID actorUserId, UUID actorEmployeeId,
                                    List<LearnedLine> lines, Map<String, String> clientFields, UUID intakeJobId,
                                    List<UUID> additionalIntakeJobIds) {
            this(docType, docId, clientId, actorUserId, actorEmployeeId, lines, clientFields, intakeJobId, additionalIntakeJobIds, null);
        }
        public SalesLearningRequest(String docType, UUID docId, UUID clientId, UUID actorUserId, UUID actorEmployeeId,
                                    List<LearnedLine> lines, Map<String, String> clientFields, UUID intakeJobId) {
            this(docType, docId, clientId, actorUserId, actorEmployeeId, lines, clientFields, intakeJobId, List.of(), null);
        }
        public SalesLearningRequest {
            Objects.requireNonNull(docType, "docType");
            Objects.requireNonNull(docId, "docId");
            lines = lines == null ? List.of() : List.copyOf(lines);
            clientFields = clientFields == null
                    ? Map.of() : Collections.unmodifiableMap(new LinkedHashMap<>(clientFields));
            additionalIntakeJobIds = additionalIntakeJobIds == null ? List.of()
                    : additionalIntakeJobIds.stream().filter(Objects::nonNull).distinct().toList();
        }

        public List<UUID> intakeJobIds() {
            var ids = new java.util.LinkedHashSet<UUID>();
            if (intakeJobId != null) ids.add(intakeJobId);
            ids.addAll(additionalIntakeJobIds);
            return List.copyOf(ids);
        }
    }

    /**
     * 一行明细的学习输入。
     *
     * @param goodsId         保存的货品
     * @param clientModel     保存的文件型号(客户的货号)
     * @param clientGoodsName 保存的文件品名(客户的描述)
     * @param intakeLineKey   识别结果里的行键(没有识别为空)
     * @param userConfirmed   用户在识别面板或明细里明确选择/改成了这个货品
     * @param setNameEn       用户勾选「设为货品英文名」
     */
    record LearnedLine(UUID goodsId, String clientModel, String clientGoodsName, String intakeLineKey,
                       boolean userConfirmed, boolean setNameEn) {
    }
}
