package com.uten.imp.features.sales;

import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.util.Map;
import java.util.List;
import java.util.UUID;

/**
 * 报价单/订货单保存请求里「这次用了客户文件识别」的附带信息(ADR-134)。
 *
 * <p>只带识别任务 id 与用户勾选要补进客户资料的字段; 识别出的型号、品名、版式一律以服务端保存的
 * 任务结果为准, 不信任请求体回传的识别内容。字段键由主档学习出口校验(只认 nameEn/fullName/
 * linkman/email/phone/mobile/address/taxId/website), 不合法在保存事务内直接 400。
 */
@Getter
@Setter
public class SalesAiIntakeRequest {

    /** 本次保存所用的 AI 识别任务 id(只能是本人提交的任务)。 */
    private UUID jobId;

    /** Other files adopted into the same customer document. Row keys are jobId:sourceKey. */
    @Size(max = 19, message = "一次最多采用 20 份识别文件")
    private List<UUID> additionalJobIds;

    /** 勾选要补进客户资料的字段; 没有勾选为空。 */
    @Size(max = 12, message = "补进客户资料的字段太多")
    private Map<@Size(max = 32) String, @Size(max = 500, message = "客户资料字段不能超过 500 个字符") String> clientFields;
}
