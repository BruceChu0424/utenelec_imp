package com.uten.imp.features.admin.disasterrecovery;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TrustedRequestOriginPolicy;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermission;
import java.time.Duration;
import java.util.Map;

/** Enrollment only. Recovery authentication and execution remain independent of ERP. */
@RestController
@RequestMapping("/api/admin/disaster-recovery")
@PreAuthorize("principal.superAdmin")
public class DisasterRecoveryEnrollmentController {
    private final SecurityContextCurrentUser currentUser;
    private final TrustedRequestOriginPolicy origins;
    private final ObjectMapper mapper;
    private final String controlUrl;
    private final String tokenFile;

    public DisasterRecoveryEnrollmentController(SecurityContextCurrentUser currentUser,
            TrustedRequestOriginPolicy origins, ObjectMapper mapper,
            @Value("${uten.disaster-recovery.control-url:http://127.0.0.1:9087}") String controlUrl,
            @Value("${uten.disaster-recovery.enrollment-token-file:}") String tokenFile) {
        this.currentUser = currentUser;
        this.origins = origins;
        this.mapper = mapper;
        this.controlUrl = controlUrl;
        this.tokenFile = tokenFile;
    }

    @PostMapping("/enrollment")
    @RequiresStepUp
    public Map<String, String> enroll() {
        var operator = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED, "请先登录"));
        if (!operator.isSuperAdmin() || operator.getImpersonatedBy() != null
                || origins.current() != TrustedRequestOriginPolicy.Origin.LOCAL) {
            throw new ApiException(ErrorCode.FORBIDDEN, "请由超级管理员本人从公司内部入口绑定救援身份");
        }
        try {
            URI base = URI.create(controlUrl);
            if (!"http".equals(base.getScheme()) || !"127.0.0.1".equals(base.getHost())
                    || base.getPort() <= 0 || base.getUserInfo() != null || base.getQuery() != null
                    || base.getFragment() != null || !(base.getPath().isEmpty() || "/".equals(base.getPath()))
                    || tokenFile.isBlank()) {
                throw new IllegalArgumentException();
            }
            Path file = Path.of(tokenFile);
            if (Files.isSymbolicLink(file) || !Files.isRegularFile(file) || Files.size(file) > 256) {
                throw new IllegalArgumentException();
            }
            if (file.getFileSystem().supportedFileAttributeViews().contains("posix")) {
                var permissions = Files.getPosixFilePermissions(file);
                if (permissions.contains(PosixFilePermission.OTHERS_READ)
                        || permissions.contains(PosixFilePermission.OTHERS_WRITE)
                        || permissions.contains(PosixFilePermission.GROUP_WRITE)) throw new IllegalArgumentException();
            }
            String token = Files.readString(file).trim();
            if (!token.matches("[A-Za-z0-9_-]{48,128}")) throw new IllegalArgumentException();
            var request = HttpRequest.newBuilder(base.resolve("/v1/broker/enrollments"))
                    .timeout(Duration.ofSeconds(5)).header("Authorization", "Bearer " + token)
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(mapper.writeValueAsString(Map.of(
                            "subject", operator.getId().toString(), "account", operator.getLoginAccount(),
                            "localSuperAdmin", true, "stepUpVerified", true)))).build();
            var response = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3))
                    .followRedirects(HttpClient.Redirect.NEVER).build()
                    .send(request, HttpResponse.BodyHandlers.ofInputStream());
            byte[] reply;
            try (var stream = response.body()) {
                reply = stream.readNBytes(4097);
            }
            if (response.statusCode() != 200 || reply.length > 4096) throw new IllegalStateException();
            var result = mapper.readTree(reply);
            String enrollment = result.path("enrollmentToken").asText();
            if (!enrollment.matches("[A-Za-z0-9_-]{48,128}")) throw new IllegalStateException();
            // Never include this response body or one-time capability in audit/logs.
            return Map.of("enrollmentToken", enrollment, "expiresAt", result.path("expiresAt").asText());
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE, "暂时无法连接独立灾备控制服务");
        } catch (Exception error) {
            throw new ApiException(ErrorCode.FORBIDDEN, "救援绑定尚未开放或暂不可用，请联系管理员核验短期绑定窗口");
        }
    }
}
