package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.web.ErrorCode;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class ServerOperationFailuresTest {
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();

    @Test void curatedCatalogMatchesTheHostPublicContractWithoutReadingRuntimeOutput() throws Exception {
        Path host = Path.of("..", "deploy", "simple", "host_operations.py");
        if (!Files.isRegularFile(host)) host = Path.of("deploy", "simple", "host_operations.py");
        String source = Files.readString(host);
        String catalog = source.substring(source.indexOf("FAILURE_CATALOG = {"), source.indexOf("\n}\n", source.indexOf("FAILURE_CATALOG = {")));
        var pattern = Pattern.compile("(?m)^    '([A-Z_]+)': \\('([^']*)', '([^']*)', '([^']*)', '([A-Z_]+)', (True|False)\\),$");
        var match = pattern.matcher(catalog);
        Set<String> found = new LinkedHashSet<>();
        while (match.find()) {
            String code = match.group(1);found.add(code);
            var entry = ServerOperationFailures.definition(code);
            assertThat(entry.title()).as(code).isEqualTo(match.group(2));
            assertThat(entry.reason()).as(code).isEqualTo(match.group(3));
            assertThat(entry.suggestion()).as(code).isEqualTo(match.group(4));
            assertThat(entry.nextAction()).as(code).isEqualTo(match.group(5));
            assertThat(entry.retrySafe()).as(code).isEqualTo("True".equals(match.group(6)));
        }
        assertThat(found).hasSize(42).containsExactlyInAnyOrderElementsOf(ServerOperationFailures.codes());
    }

    @Test void helperTextAndFlagsCannotOverrideCuratedEarlyPhaseGuidance() throws Exception {
        var raw = failure("SOURCE_NETWORK_FAILED").put("phase", "MIGRATING").put("title", "RAW_TITLE")
                .put("reason", "<Error>SECRET_TOKEN</Error>").put("suggestion", "https://private.invalid")
                .put("nextAction", "REPLAY_UPDATE").put("retrySafe", false).put("exitCode", 7);
        var view = ServerOperationFailures.project(raw, "FAILED", "CHECKING");
        assertThat(view.phase()).isEqualTo("CHECKING");
        assertThat(view.nextAction()).isEqualTo("CHECK_SOURCE");
        assertThat(view.retrySafe()).isTrue();assertThat(view.recoveryRequired()).isFalse();
        assertThat(view.originalServicePreserved()).isTrue();assertThat(view.exitCode()).isEqualTo(7);
        assertThat(mapper.writeValueAsString(view)).doesNotContain("RAW_TITLE", "SECRET_TOKEN", "private.invalid", "REPLAY_UPDATE");
    }

    @Test void localPlatformCodeIsExcludedFromEveryHelperControlledProjection() {
        assertThat(ServerOperationFailures.known("HOST_PLATFORM_UNSUPPORTED")).isFalse();
        assertThat(ServerOperationFailures.codes()).doesNotContain("HOST_PLATFORM_UNSUPPORTED");
        assertThat(ServerOperationFailures.unavailable("HOST_PLATFORM_UNSUPPORTED").code()).isEqualTo("HOST_HELPER_UNAVAILABLE");
        var receipt=ServerOperationFailures.project(failure("HOST_PLATFORM_UNSUPPORTED"),"FAILED","CHECKING");
        assertThat(receipt.code()).isEqualTo("UNKNOWN");
        assertThat(receipt.retrySafe()).isFalse();
        assertThat(HostOperationsException.platformUnsupported().availabilityFailure().code()).isEqualTo("HOST_PLATFORM_UNSUPPORTED");
    }

    @Test void latePhasesAndRecoveryStateAlwaysSuppressRetryAndPreservationClaims() {
        for (String phase : Set.of("MIGRATING", "ACTIVATING", "HEALTH_CHECK", "DONE")) {
            var view = ServerOperationFailures.project(failure("SOURCE_NETWORK_FAILED").put("recoveryRequired", false), "FAILED", phase);
            assertRecovery(view);
        }
        assertRecovery(ServerOperationFailures.project(failure("CURRENT_VERSION_CHANGED"), "RECOVERY_REQUIRED", "CHECKING"));
        assertRecovery(ServerOperationFailures.project(failure("MIGRATION_FAILED"), "FAILED", "CHECKING"));
        assertRecovery(ServerOperationFailures.project(failure("BUSY").put("recoveryRequired", true), "FAILED", "CHECKING"));
    }

    @Test void verifiedPreconditionFailuresRemainFailedAndPreservedUnlessRecoveryWasRequired() {
        for (String code : Set.of("CURRENT_VERSION_CHANGED", "CUTOVER_BACKUP_FAILED_RECOVERED")) {
            var view = ServerOperationFailures.project(failure(code), "FAILED", "ACTIVATING");
            assertThat(view.recoveryRequired()).isFalse();assertThat(view.originalServicePreserved()).isTrue();
            assertThat(view.nextAction()).isNotEqualTo("VERIFY_RECOVERY");
            var contradictory = ServerOperationFailures.project(failure(code), "RECOVERY_REQUIRED", "ACTIVATING");
            assertRecovery(contradictory);
            assertThat(contradictory.title()).isEqualTo("更新需要恢复核对");
            assertThat(contradictory.reason()).doesNotContain("未停服", "未迁移", "已恢复健康");
            var unconfirmed = ServerOperationFailures.project(failure(code).put("originalServicePreserved", false), "FAILED", "ACTIVATING");
            assertThat(unconfirmed.recoveryRequired()).isFalse();
            assertThat(unconfirmed.originalServicePreserved()).isFalse();
            assertThat(unconfirmed.title()).isEqualTo("更新状态需要核对");
            assertThat(unconfirmed.reason()).contains("尚未获得可确认").doesNotContain("已恢复健康", "本次未停服");
        }
    }

    @Test void missingOrMalformedPreservationFlagNeverPromisesTheOriginalService() {
        for (var raw : new ObjectNode[]{failure("BUSY").removeAll().put("code", "BUSY"), failure("BUSY").put("originalServicePreserved", "true")}) {
            assertThat(ServerOperationFailures.project(raw, "FAILED", "CHECKING").originalServicePreserved()).isFalse();
        }
    }

    @Test void onlyBoundedNonzeroIntegralExitCodesAreExposedAndUnknownCodesLoseThem() {
        for (int code : new int[]{-255,-1,1,255}) {
            assertThat(ServerOperationFailures.project(failure("HOST_IDENTITY_PERMISSION").put("exitCode", code), "FAILED", "CHECKING").exitCode()).isEqualTo(code);
        }
        for (String json : new String[]{"0", "256", "-256", "1.0", "true", "\"1\"", "999999999999999999999999"}) {
            var raw = failure("HOST_IDENTITY_PERMISSION");
            try {raw.set("exitCode", mapper.readTree(json));} catch (Exception impossible) {throw new AssertionError(impossible);}
            assertThat(ServerOperationFailures.project(raw, "FAILED", "CHECKING").exitCode()).as(json).isNull();
        }
        var unknown = ServerOperationFailures.project(failure("UNREVIEWED_RAW_PRIVATE_CODE").put("exitCode", 1), "FAILED", "CHECKING");
        assertThat(unknown.code()).isEqualTo("UNKNOWN");assertThat(unknown.exitCode()).isNull();assertThat(unknown.retrySafe()).isFalse();
    }

    @Test void legacyAndSuccessfulReceiptsDoNotAcquireInventedFailures() {
        assertThat(ServerOperationFailures.project(null, "FAILED", "CHECKING")).isNull();
        for (String state : Set.of("SUCCEEDED", "CANCELLED", "RUNNING", "QUEUED", "SCHEDULED")) {
            assertThat(ServerOperationFailures.project(failure("UNKNOWN"), state, "CHECKING")).isNull();
        }
    }

    @Test void synchronousErrorsRetainErrorCodesAndUnknownOutcomeWithoutForwardingRawDetails() {
        assertThat(new HostOperationsException("INVALID_RESPONSE").toApiException().getMessage()).contains("协议").doesNotContain("尚未安装");
        assertThat(new HostOperationsException("UNAVAILABLE").toApiException().getMessage()).contains("可信连接").doesNotContain("尚未安装");
        assertThat(new HostOperationsException("BUSY").toApiException().getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(new HostOperationsException("STALE_CONFIG").toApiException().getCode()).isEqualTo(ErrorCode.CONFLICT);
        var recovery = new HostOperationsException("RECOVERY_REQUIRED").toApiException();
        assertThat(recovery.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(recovery.getMessage()).contains("已有更新", "尚不能确认", "不要再次更新、激活或回滚数据库");
        assertRecovery(ServerOperationFailures.project(failure("RECOVERY_REQUIRED"), "FAILED", "CHECKING"));
        for (String code : Set.of("STALE_PREVIEW", "PROTECTED")) {
            var cleanup = new HostOperationsException(code).toApiException();
            assertThat(cleanup.getCode()).isEqualTo(ErrorCode.CONFLICT);
            assertThat(cleanup.getMessage()).contains("清理预览", "受保护资源").doesNotContain("原因尚未确认");
        }
        var uncertain = new HostOperationsException("SOURCE_NETWORK_FAILED", true).toApiException();
        assertThat(uncertain.getCode()).isEqualTo(ErrorCode.SERVER_OPERATION_OUTCOME_UNCERTAIN);
        assertThat(uncertain.getMessage()).contains("原任务标识", "不要更换标识");
        assertThat(new HostOperationsException("PRIVATE_SECRET_URL").toApiException().getMessage()).doesNotContain("PRIVATE_SECRET_URL");
    }

    private ObjectNode failure(String code) {return mapper.createObjectNode().put("code",code).put("originalServicePreserved",true);}
    private static void assertRecovery(ServerOperationsDto.Failure view) {
        assertThat(view.recoveryRequired()).isTrue();assertThat(view.retrySafe()).isFalse();
        assertThat(view.originalServicePreserved()).isFalse();assertThat(view.nextAction()).isEqualTo("VERIFY_RECOVERY");
        assertThat(view.suggestion()).contains("完成恢复核对", "不要再次更新、激活或回滚数据库");
    }
}
