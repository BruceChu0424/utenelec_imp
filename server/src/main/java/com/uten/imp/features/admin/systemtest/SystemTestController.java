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
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

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

    public record ResetBusinessDataRequest(@NotBlank String confirm) {
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
        return businessDataResetService.reset(operator.getId(), operator.getLoginAccount());
    }
}
