package com.uten.imp.features.admin.systemtest;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 工作台「系统测试」区后端入口。
 *
 * <p>清空业务数据是破坏性测试操作，四重门禁缺一不可：</p>
 * <ol>
 *   <li>运行开关 {@code uten.features.business-data-reset-enabled}——仅 dev /
 *       internal-test profile 开启，生产与云端 fail closed（403 拒绝）；</li>
 *   <li>数据库确认的超级管理员本人（principal.superAdmin，@PreAuthorize 独立于前端）；</li>
 *   <li>请求体确认口令必须逐字等于「清空业务数据」，防误触；</li>
 *   <li>服务端排水闸（见 {@link BusinessDataResetService}）保证清空期间无并发业务写。</li>
 * </ol>
 *
 * <p>不设独立权限码：这是超管专属测试工具，不进入权限目录/部门授权体系。</p>
 */
@RestController
@RequestMapping("/api/system-test")
@RequiredArgsConstructor
@PreAuthorize("principal.superAdmin")
public class SystemTestController {

    /** 与前端确认弹窗共用的口令；逐字匹配才执行。 */
    static final String CONFIRM_PHRASE = "清空业务数据";

    private final BusinessDataResetService businessDataResetService;
    private final SecurityContextCurrentUser currentUser;
    private final BusinessAttachmentResetPreparationService attachmentPreparation;

    public record PrepareAttachmentsRequest(@NotBlank String confirm,
            @NotBlank String database, @NotBlank String fingerprint) {}

    @GetMapping("/business-data/attachments/preview")
    public com.uten.imp.application.port.BusinessAttachmentResetPreparationPort.Preview previewAttachments() {
        return attachmentPreparation.preview(currentUser.requireId());
    }

    @PostMapping("/business-data/attachments/prepare")
    public com.uten.imp.application.port.BusinessAttachmentResetPreparationPort.Preview prepareAttachments(
            @Valid @RequestBody PrepareAttachmentsRequest request) {
        if (!"清理测试业务附件".equals(request.confirm())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请逐字输入「清理测试业务附件」");
        }
        AuthUser operator = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        return attachmentPreparation.prepare(operator.getId(), operator.getLoginAccount(),
                new com.uten.imp.application.port.BusinessAttachmentResetPreparationPort.Confirmation(
                        request.database(), request.fingerprint()));
    }

    /**
     * 上次清空结果（audit_log 最近一条 business_data_reset 显式事件）。
     *
     * <p>清空是同步长请求：客户端/网关超时后服务端仍会执行完并把全员踢下线，发起人
     * 重登后工作台系统测试区用本端点回显「上次清空」结果，区分「失败」与「已成功但断连」。
     * 只读、不进排水豁免（重登本身发生在清空完成之后）；门禁同预览端点（运行开关 + 超管）。</p>
     */
    @GetMapping("/business-data/last-result")
    public BusinessDataResetService.LastResult lastBusinessDataResult(
            @RequestParam(required = false) UUID attemptId) {
        return businessDataResetService.lastResult(currentUser.requireId(), attemptId);
    }

    public record ResetBusinessDataRequest(@NotBlank String confirm, UUID attemptId) {
        public ResetBusinessDataRequest(String confirm) { this(confirm, null); }
    }

    /** 清空业务数据（保留基础资料/人事/权限，业务表从 1 重新编号，全员下线重登）。 */
    @PostMapping("/business-data/reset")
    public BusinessDataResetService.Result resetBusinessData(
            @Valid @RequestBody ResetBusinessDataRequest request) {
        if (!CONFIRM_PHRASE.equals(request.confirm())) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "确认口令不正确：请逐字输入「" + CONFIRM_PHRASE + "」");
        }
        AuthUser operator = currentUser.get().orElseThrow(
                () -> new ApiException(ErrorCode.UNAUTHORIZED, "请先登录"));
        return businessDataResetService.reset(operator.getId(), operator.getLoginAccount(), request.attemptId());
    }
}
