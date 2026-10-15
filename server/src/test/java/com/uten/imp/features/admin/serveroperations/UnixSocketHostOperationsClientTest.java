package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class UnixSocketHostOperationsClientTest {
    private final ObjectMapper mapper = new ObjectMapper();
    @Test void fixedFrameEscapesCredentialsAndKeepsActorAndRequestIdentity() throws Exception {
        UUID actor=UUID.randomUUID(),request=UUID.randomUUID();
        byte[] bytes=UnixSocketHostOperationsClient.requestFrame(mapper,HostOperationsClient.Operation.CONFIG_SAVE,
                Map.of("accessKeySecret","private\nline"),actor,request);
        String frame=new String(bytes,StandardCharsets.UTF_8);
        assertThat(frame.chars().filter(c->c=='\n').count()).isEqualTo(1);
        var json=mapper.readTree(frame);
        assertThat(json.path("actorId").asText()).isEqualTo(actor.toString());
        assertThat(json.path("requestId").asText()).isEqualTo(request.toString());
        assertThat(json.path("payload").path("accessKeySecret").asText()).isEqualTo("private\nline");
    }
    @Test void oversizedUtf8FramesAreRejectedBeforeTransport() {
        assertThatThrownBy(()->UnixSocketHostOperationsClient.requestFrame(mapper,HostOperationsClient.Operation.CONFIG_SAVE,
                Map.of("accessKeySecret","密".repeat(23000)),UUID.randomUUID(),UUID.randomUUID()))
                .isInstanceOf(HostOperationsException.class).hasMessageNotContaining("密");
    }
    @Test void helperRawErrorsNeverEscape() {
        var failure=catchThrowableOfType(()->decode("{\"ok\":false,\"code\":\"UNKNOWN_PRIVATE_KEY\",\"message\":\"SECRET123\"}",
                HostOperationsClient.Operation.CONFIG_READ),HostOperationsException.class);
        assertThat(failure.code()).isEqualTo("UNAVAILABLE");
        assertThat(failure.getMessage()).doesNotContain("SECRET123","UNKNOWN_PRIVATE_KEY");
        assertThat(failure.getCause()).isNull();
    }
    @Test void malformedMutationResponseIsUncertainAndCannotBeAutomaticallyReplayed() {
        for(String frame: new String[]{"{}","{\"ok\":true,\"data\":{}} trailing","{\"ok\":true,\"data\":null}"}) {
            var failure=catchThrowableOfType(()->decode(frame,HostOperationsClient.Operation.UPDATE_START),HostOperationsException.class);
            assertThat(failure.uncertain()).isTrue();
        }
        assertThat(decode("{\"ok\":true,\"data\":null}",HostOperationsClient.Operation.UPDATE_JOB).isNull()).isTrue();
    }
    @Test void malformedUtf8IsRejected() {
        assertThatThrownBy(()->UnixSocketHostOperationsClient.responseData(mapper,new byte[]{(byte)0xc3,(byte)0x28},
                HostOperationsClient.Operation.STATUS)).isInstanceOf(HostOperationsException.class);
    }
    @Test void explicitUnknownOutcomeAndDstErrorsAreNotMisreportedAsMissingInstallation() {
        var unknown=catchThrowableOfType(()->decode("{\"ok\":false,\"code\":\"OUTCOME_UNCERTAIN\",\"message\":\"raw secret\"}",
                HostOperationsClient.Operation.CONFIG_SAVE),HostOperationsException.class);
        assertThat(unknown.uncertain()).isTrue();
        assertThat(unknown.toApiException().getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.SERVER_OPERATION_OUTCOME_UNCERTAIN);
        assertThat(new HostOperationsException("AMBIGUOUS_SCHEDULE").toApiException().getMessage()).contains("夏令时");
        assertThat(new HostOperationsException("UNSAFE_HOST_CONFIG").toApiException().getMessage()).contains("安全校验").doesNotContain("尚未安装");
        assertThat(new HostOperationsException("INVALID_RUNTIME_BINDING").toApiException().getMessage())
                .contains("数据库", "附件存储").doesNotContain("尚未安装");
        assertThat(new HostOperationsException("BACKUP_BINDING_MISMATCH").toApiException().getCode())
                .isEqualTo(com.uten.imp.common.web.ErrorCode.CONFLICT);
    }
    @Test void windowsHasHonestUnavailableAndStorageGetsItsBoundedScanDeadline() {
        var client=new UnixSocketHostOperationsClient(mapper,Path.of("/run/uten-imp-operations/control.sock"),Duration.ofSeconds(5),false);
        assertThatThrownBy(()->client.call(HostOperationsClient.Operation.STATUS,Map.of(),UUID.randomUUID(),UUID.randomUUID()))
                .isInstanceOf(HostOperationsException.class);
        assertThat(client.deadlineFor(HostOperationsClient.Operation.STATUS)).isEqualTo(Duration.ofSeconds(5));
        assertThat(client.deadlineFor(HostOperationsClient.Operation.STORAGE_SUMMARY)).isEqualTo(Duration.ofSeconds(15));
        assertThat(client.deadlineFor(HostOperationsClient.Operation.STORAGE_DELETE)).isEqualTo(Duration.ofSeconds(15));
    }
    private com.fasterxml.jackson.databind.JsonNode decode(String frame,HostOperationsClient.Operation op) {
        return UnixSocketHostOperationsClient.responseData(mapper,frame.getBytes(StandardCharsets.UTF_8),op);
    }
}
