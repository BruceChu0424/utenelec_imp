package com.uten.imp.features.admin;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.admin.dto.TemporaryPasswordResetRequest;
import com.uten.imp.features.admin.dto.TemporaryPasswordResponse;
import jakarta.validation.Validation;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.*;

class TemporaryPasswordRequestContractTest {
    @Test void preservesExplicitInputButNeverSerializesOrPrintsRequestCredentials() throws Exception {
        var mapper=new ObjectMapper();
        String value="  Selected-临时-7!  ";
        var request=mapper.readValue(mapper.writeValueAsBytes(java.util.Map.of("temporaryPassword",value)),TemporaryPasswordResetRequest.class);
        assertThat(request.temporaryPassword()).isEqualTo(value);
        assertThat(mapper.writeValueAsString(request)).isEqualTo("{}");
        assertThat(request.toString()).doesNotContain(value).contains("REDACTED");
        var response=new TemporaryPasswordResponse(value);
        assertThat(mapper.readTree(mapper.writeValueAsBytes(response)).path("temporaryPassword").asText()).isEqualTo(value);
        assertThat(response.toString()).doesNotContain(value).contains("REDACTED");
        assertThat(mapper.readValue("{}",TemporaryPasswordResetRequest.class).temporaryPassword()).isNull();
        assertThat(mapper.readValue("{\"temporaryPassword\":null}",TemporaryPasswordResetRequest.class).temporaryPassword()).isNull();
    }

    @Test void validatesBlankInputBeforeStepUpWithoutAddingLengthOrCharacterRules() {
        try(var factory=Validation.buildDefaultValidatorFactory()) {
            var validator=factory.getValidator();
            assertThat(validator.validate(new TemporaryPasswordResetRequest(null))).isEmpty();
            for(String value:java.util.List.of("", " \t\n", "\u2003"))
                assertThat(validator.validate(new TemporaryPasswordResetRequest(value))).hasSize(1);
            for(String value:java.util.List.of("1", "  exact value  ", "密".repeat(130)))
                assertThat(validator.validate(new TemporaryPasswordResetRequest(value))).isEmpty();
        }
    }

    @Test void unknownBodyFieldsCannotSilentlySelectRandomMode() {
        assertThatThrownBy(()->new ObjectMapper().readValue("{\"password\":\"chosen-secret\"}",TemporaryPasswordResetRequest.class))
                .isInstanceOf(com.fasterxml.jackson.core.JsonProcessingException.class);
    }

    @Test void nonStringCredentialsCannotBeSilentlyCoerced() {
        var mapper=new ObjectMapper();
        for(String value:java.util.List.of("123456", "true", "[]", "{}")) {
            assertThatThrownBy(()->mapper.readValue("{\"temporaryPassword\":"+value+"}",TemporaryPasswordResetRequest.class))
                    .isInstanceOf(com.fasterxml.jackson.core.JsonProcessingException.class)
                    .hasMessageContaining("临时密码必须为字符串或 null");
        }
    }
}
