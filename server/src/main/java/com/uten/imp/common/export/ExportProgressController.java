package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 同步导出生成进度(2026-11-08)。客户端在导出请求进行中定时读取本人那次导出的
 * 「已读 / 总数 / 阶段」; 未开始或已结束返回 204(客户端保持当前进度, 不当作失败)。
 * 这是轮询的正常状态, 不用 404: 审计拦截器会把每个 4xx 记成一条失败操作。
 * 只返回调用者本人登记的进度, 不涉及任何业务数据。
 */
@RestController
@RequestMapping("/api/exports/progress")
public class ExportProgressController {
    private final SecurityContextCurrentUser users;

    public ExportProgressController(SecurityContextCurrentUser users) {
        this.users = users;
    }

    @GetMapping("/{operation}")
    public ResponseEntity<ExportProgress.Snapshot> progress(@PathVariable UUID operation) {
        UUID user = users.id().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        return ExportProgress.snapshot(user, operation)
                .map(ResponseEntity::ok)
                .orElseGet(() -> ResponseEntity.noContent().build());
    }
}
