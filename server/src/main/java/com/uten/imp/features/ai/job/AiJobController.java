package com.uten.imp.features.ai.job;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.util.MultiValueMap;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 公共 AI 识别任务接口(ADR-133)。只有员工账号能用(访客一律 403); 模拟身份期间提交与取消被
 * 只读守卫拦截(ImpersonationWriteGuardFilter 不放行本路径)。
 *
 * <ul>
 *   <li>{@code POST /api/ai/jobs?kind=...&<参数>}: 请求体是原始文件字节(application/octet-stream),
 *       请求头 {@code X-Uten-File-Name}(百分号编码的 UTF-8 文件名)、{@code X-Uten-File-Type}; 返回 202 与任务快照。</li>
 *   <li>{@code GET /api/ai/jobs/{id}}: 只有提交人本人(其他人 404), 结果按当前权限过滤。</li>
 *   <li>{@code POST /api/ai/jobs/{id}/cancel}: 只有提交人本人。</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/ai/jobs")
@PreAuthorize("isAuthenticated() and !principal.visitor")
public class AiJobController {

    /**
     * 上传请求头。浏览器跨源提交(Flutter Web 开发端口、办公网页访问云端接口)需要它们出现在 CORS 允许的请求头里
     * ({@code SecurityConfig.corsConfigurationSource}), 否则预检失败、文件传不上来。
     */
    public static final String HEADER_FILE_NAME = "X-Uten-File-Name";
    public static final String HEADER_FILE_TYPE = "X-Uten-File-Type";

    private final AiJobService service;
    private final SecurityContextCurrentUser currentUser;

    public AiJobController(AiJobService service, SecurityContextCurrentUser currentUser) {
        this.service = service;
        this.currentUser = currentUser;
    }

    @PostMapping
    public ResponseEntity<AiJobView> submit(
            @RequestParam MultiValueMap<String, String> query,
            @RequestHeader(value = HEADER_FILE_NAME, required = false) String fileName,
            @RequestHeader(value = HEADER_FILE_TYPE, required = false) String fileType,
            HttpServletRequest request) throws IOException {
        String kind = single(query, "kind");
        if (kind == null || kind.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "缺少识别任务种类");
        }
        Map<String, String> params = new LinkedHashMap<>();
        for (Map.Entry<String, List<String>> entry : query.entrySet()) {
            if (!"kind".equals(entry.getKey())) {
                params.put(entry.getKey(), single(query, entry.getKey()));
            }
        }
        String type = fileType != null ? fileType : request.getContentType();
        AiJobView view = service.submit(kind, params, fileName, type, request.getInputStream(),
                request.getContentLengthLong(), user());
        return ResponseEntity.status(HttpStatus.ACCEPTED).body(view);
    }

    @GetMapping("/{id}")
    public AiJobView get(@PathVariable UUID id) {
        return service.view(id, user());
    }
    @GetMapping("/{id}/history")
    public Map<String,Object> history(@PathVariable UUID id){return service.history(id,user());}

    @PostMapping("/{id}/cancel")
    public AiJobView cancel(@PathVariable UUID id) {
        return service.cancel(id, user());
    }

    private static String single(MultiValueMap<String, String> query, String key) {
        List<String> values = query.get(key);
        if (values == null || values.isEmpty()) {
            return null;
        }
        if (values.size() > 1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "识别的附加设置不能重复: " + key);
        }
        return values.get(0);
    }

    private AuthUser user() {
        return currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
    }
}
