package com.uten.imp.features.sales;

import com.uten.imp.application.port.SalesMasterLearningPort;
import com.uten.imp.application.port.SalesMasterLearningPort.LearnedLine;
import com.uten.imp.application.port.SalesMasterLearningPort.SalesLearningRequest;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.intake.SalesIntakeUsedEvent;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 报价单/订货单保存后的「学习」挂钩(ADR-134)。
 *
 * <p>在保存事务内、明细落库之后调用: 把带客户文件原文(文件型号/品名)的行和勾选的客户资料交给
 * {@link SalesMasterLearningPort}(它先在事务内校验客户字段, 提交后在独立事务里学习, 学习失败不影响保存);
 * 用了识别任务时再发布 {@link SalesIntakeUsedEvent}, 识别模块提交后据此记住表格版式。
 * 既没有识别任务、也没有任何文件原文的保存什么都不做。只学基础资料, 从不学习或修改价格。
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class SalesIntakeSaveHooks {

    public static final String DOC_QUOTE = "quote";
    public static final String DOC_ORDER = "order";

    private final ObjectProvider<SalesMasterLearningPort> learning;
    private final ApplicationEventPublisher events;
    private final SecurityContextCurrentUser currentUser;

    /**
     * 保存事务内调用。{@code lines} 为本次保存后的全部明细(调用方已按保存结果组装),
     * 只有带文件原文或识别行键的行会交给学习出口。
     */
    public void afterSave(String docType, UUID docId, UUID clientId,
                          List<LearnedLine> lines, SalesAiIntakeRequest aiIntake) {
        UUID jobId = aiIntake == null ? null : aiIntake.getJobId();
        List<LearnedLine> learnable = lines == null ? List.of() : lines.stream()
                .filter(line -> line != null && line.goodsId() != null)
                .filter(line -> hasText(line.clientModel()) || hasText(line.clientGoodsName())
                        || hasText(line.intakeLineKey()))
                .toList();
        if (jobId == null && learnable.isEmpty()) {
            return;
        }
        UUID userId = currentUser.requireId();
        UUID employeeId = currentUser.employeeId().orElse(null);
        Map<String, String> clientFields = clientFields(aiIntake);
        SalesMasterLearningPort port = learning.getIfAvailable();
        if (port != null) {
            port.learnAfterCommit(new SalesLearningRequest(
                    docType, docId, clientId, userId, employeeId, learnable, clientFields, jobId));
        } else if (!clientFields.isEmpty()) {
            // 勾选的客户资料必须在保存事务内校验并写入(学习出口负责); 出口不在时不能静默丢掉用户勾选的内容。
            throw new ApiException(ErrorCode.CONFLICT, "暂时不能从客户文件补全客户资料, 请取消勾选客户资料后再保存");
        } else {
            // 货品叫法学习本来就是尽力而为(失败只记日志, 不影响保存)。
            log.warn("sales master learning port unavailable; {} {} saved without learning", docType, docId);
        }
        if (jobId != null) {
            events.publishEvent(new SalesIntakeUsedEvent(jobId, userId, docType, docId, clientId));
        }
    }

    private static Map<String, String> clientFields(SalesAiIntakeRequest aiIntake) {
        if (aiIntake == null || aiIntake.getClientFields() == null) return Map.of();
        Map<String, String> fields = new LinkedHashMap<>();
        aiIntake.getClientFields().forEach((key, value) -> {
            if (key != null && value != null && !value.isBlank()) fields.put(key.strip(), value.strip());
        });
        return fields;
    }

    private static boolean hasText(String value) {
        return value != null && !value.isBlank();
    }
}
