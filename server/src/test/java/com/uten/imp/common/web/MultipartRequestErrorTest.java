package com.uten.imp.common.web;

import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MaxUploadSizeExceededException;
import org.springframework.web.multipart.MultipartException;
import org.springframework.web.multipart.MultipartFile;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class MultipartRequestErrorTest {
    private final MockMvc mvc = MockMvcBuilders.standaloneSetup(new UploadController())
            .setControllerAdvice(new GlobalExceptionHandler()).build();

    @Test
    void unsupportedContentTypeDoesNotBecomeAnInternalError() throws Exception {
        mvc.perform(post("/upload").contentType(MediaType.APPLICATION_JSON).content("{}"))
                .andExpect(status().isUnsupportedMediaType())
                .andExpect(jsonPath("$.status").value(415))
                .andExpect(jsonPath("$.code").value("UNSUPPORTED_MEDIA_TYPE"));
    }

    @Test
    void missingPartIsAConsistentBadRequest() throws Exception {
        mvc.perform(multipart("/upload"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.status").value(400))
                .andExpect(jsonPath("$.code").value("MALFORMED_REQUEST"));
    }

    @Test
    void malformedUploadIsSanitizedAndSizeFailuresKeepTheirOwnStatus() throws Exception {
        for (String name : new String[]{"malformed", "oversized"}) {
            int expected = name.equals("oversized") ? 413 : 400;
            mvc.perform(multipart("/upload").file(new MockMultipartFile("file", name, "image/png", new byte[]{1})))
                    .andExpect(status().is(expected))
                    .andExpect(jsonPath("$.status").value(expected))
                    .andExpect(jsonPath("$.message").value(org.hamcrest.Matchers.not(
                            org.hamcrest.Matchers.containsString("private multipart details"))));
        }
    }

    @RestController
    static class UploadController {
        @PostMapping(value = "/upload", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
        String upload(@RequestParam("file") MultipartFile file) {
            if ("oversized".equals(file.getOriginalFilename())) throw new MaxUploadSizeExceededException(1);
            throw new MultipartException("private multipart details");
        }
    }
}
