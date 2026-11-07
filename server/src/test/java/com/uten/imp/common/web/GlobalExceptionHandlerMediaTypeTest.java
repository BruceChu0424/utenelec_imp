package com.uten.imp.common.web;

import jakarta.servlet.http.HttpServletResponse;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import java.io.IOException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class GlobalExceptionHandlerMediaTypeTest {
    private MockMvc mvc;
    @BeforeEach void setup() {
        mvc=MockMvcBuilders.standaloneSetup(new StreamController())
                .setControllerAdvice(new GlobalExceptionHandler()).build();
    }

    @Test void rejectedStreamKeepsOriginal422AndJsonError() throws Exception {
        mvc.perform(get("/stream/reject").accept("application/x-ndjson"))
                .andExpect(status().is(422))
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
                .andExpect(jsonPath("$.code").value("VALIDATION_FAILED"))
                .andExpect(jsonPath("$.message").value("original validation reason"));
    }
    @Test void busyStreamKeepsOriginalRetryAfterAndAuthCode() throws Exception {
        mvc.perform(get("/stream/busy").accept("application/x-ndjson"))
                .andExpect(status().isServiceUnavailable()).andExpect(header().string("Retry-After","1"))
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
                .andExpect(jsonPath("$.code").value("AUTH_BUSY"));
    }
    @Test void invalidBodyRetainsItsFieldErrorUnderAStreamAcceptHeader() throws Exception {
        mvc.perform(post("/stream/body").accept("application/x-ndjson")
                .contentType(MediaType.APPLICATION_JSON).content("{}"))
                .andExpect(status().is(422))
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
                .andExpect(jsonPath("$.fieldErrors[0].field").value("value"));
    }
    @Test void deniedStreamRetains403AndNeverExposesThePrivateReason() throws Exception {
        mvc.perform(get("/stream/denied").accept("application/x-ndjson"))
                .andExpect(status().isForbidden())
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
                .andExpect(jsonPath("$.code").value("FORBIDDEN"))
                .andExpect(content().string(org.hamcrest.Matchers.not(org.hamcrest.Matchers.containsString("private"))));
    }
    @Test void wrongMappingParameterIsAMalformedRequestAndNeverAnInternalFailure() throws Exception {
        mvc.perform(get("/stream/required").param("complete","false").accept("application/x-ndjson"))
                .andExpect(status().isBadRequest())
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
                .andExpect(jsonPath("$.code").value("MALFORMED_REQUEST"));
    }
    @Test void missingRequiredQueryRetains400UnderAStreamAcceptHeader() throws Exception {
        mvc.perform(get("/stream/query").accept("application/x-ndjson"))
                .andExpect(status().isBadRequest())
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
                .andExpect(jsonPath("$.code").value("MALFORMED_REQUEST"));
    }
    @Test void ordinaryJsonErrorsRetainTheirOriginalContract() throws Exception {
        mvc.perform(get("/json/reject").accept(MediaType.APPLICATION_JSON))
                .andExpect(status().is(422))
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
                .andExpect(jsonPath("$.message").value("original validation reason"));
    }
    @Test void anUnexpectedStreamFailureRemains500WithoutLeakingItsDetails() throws Exception {
        mvc.perform(get("/stream/broken").accept("application/x-ndjson"))
                .andExpect(status().isInternalServerError())
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
                .andExpect(jsonPath("$.code").value("INTERNAL"))
                .andExpect(content().string(org.hamcrest.Matchers.not(org.hamcrest.Matchers.containsString("private"))));
    }
    @Test void acceptedStreamKeepsItsNdjsonBytes() throws Exception {
        mvc.perform(get("/stream/success").accept("application/x-ndjson"))
                .andExpect(status().isOk()).andExpect(content().contentType("application/x-ndjson"))
                .andExpect(content().string("{\"type\":\"complete\",\"total\":0}\n"));
    }

    record Input(@NotNull String value) { }
    @org.springframework.boot.test.context.TestComponent
    @RestController static class StreamController {
        @GetMapping(value="/stream/reject",produces="application/x-ndjson")
        void reject() { throw new ApiException(ErrorCode.VALIDATION_FAILED,"original validation reason"); }
        @GetMapping(value="/stream/busy",produces="application/x-ndjson")
        void busy() { throw new ApiException(ErrorCode.AUTH_BUSY); }
        @PostMapping(value="/stream/body",produces="application/x-ndjson")
        void body(@Valid @RequestBody Input input) { throw new AssertionError("Invalid body reached the owner"); }
        @GetMapping(value="/stream/denied",produces="application/x-ndjson")
        void denied() { throw new AccessDeniedException("private authorization detail"); }
        @GetMapping(value="/stream/required",params="complete=true",produces="application/x-ndjson")
        void required() { throw new AssertionError("Wrong mapping parameter reached the owner"); }
        @GetMapping(value="/stream/query",produces="application/x-ndjson")
        void query(@RequestParam("id") String id) { throw new AssertionError("Missing query reached the owner"); }
        @GetMapping(value="/json/reject",produces="application/json")
        void jsonReject() { reject(); }
        @GetMapping(value="/stream/broken",produces="application/x-ndjson")
        void broken() { throw new IllegalStateException("private implementation detail"); }
        @GetMapping(value="/stream/success",produces="application/x-ndjson")
        void success(HttpServletResponse response) throws IOException {
            response.setContentType("application/x-ndjson");
            response.getWriter().write("{\"type\":\"complete\",\"total\":0}\n");
        }
    }
}
