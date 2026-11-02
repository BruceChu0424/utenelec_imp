package com.uten.imp.common.web;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class ErrorCodeUserMessageTest {
    @Test void genericPermissionAndServerFailuresStateTheCauseAndSafeNextStep() {
        assertThat(new ApiException(ErrorCode.FORBIDDEN).getMessage())
                .isEqualTo("此账号没有进行该操作的权限，请联系管理员");
        assertThat(new ApiException(ErrorCode.INTERNAL).getMessage())
                .isEqualTo("服务器处理异常，请先刷新核对操作结果");
        assertThat(ErrorCode.FORBIDDEN.getHttpStatus()).isEqualTo(403);
        assertThat(ErrorCode.INTERNAL.getHttpStatus()).isEqualTo(500);
    }

    @Test void specificBusinessRefusalAndUncertainSubmissionRemainAuthoritative() {
        var specific = new ApiException(ErrorCode.FORBIDDEN, "当前账号没有查看客户价格的权限");
        assertThat(specific.getMessage()).isEqualTo("当前账号没有查看客户价格的权限");
        assertThat(specific.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        assertThat(ErrorCode.SERVER_OPERATION_OUTCOME_UNCERTAIN.getDefaultMessage())
                .isEqualTo("服务器操作结果待确认，请刷新状态后核对，不要重复提交");
    }
}
