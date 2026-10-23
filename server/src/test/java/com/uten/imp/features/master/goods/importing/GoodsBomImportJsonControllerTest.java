package com.uten.imp.features.master.goods.importing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.AdditionalMatchers.aryEq;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class GoodsBomImportJsonControllerTest {
    private final GoodsBomImportService service = mock(GoodsBomImportService.class);
    private final GoodsBomImportController controller = new GoodsBomImportController(service);
    private final UUID goodsId = UUID.randomUUID();

    @Test void jsonAndRawMappingsAreUnambiguousAndPassTheSameSelection() throws Exception {
        byte[] file = {1, 2, 3}; Set<String> selected = Set.of("bom:parent:component");
        var mvc = MockMvcBuilders.standaloneSetup(controller).build();
        mvc.perform(post("/api/master/goods/" + goodsId + "/bom/import/commit")
                        .contentType("application/json").content(new ObjectMapper().writeValueAsBytes(Map.of(
                                "file", file, "mode", "MERGE", "stateFingerprint", "v1:token", "replaceRowKeys", selected))))
                .andExpect(status().isOk());
        mvc.perform(post("/api/master/goods/" + goodsId + "/bom/import/commit")
                        .contentType("application/octet-stream").queryParam("mode", "MERGE")
                        .queryParam("stateFingerprint", "v1:token").queryParam("replaceRowKeys", "bom:parent:component").content(file))
                .andExpect(status().isOk());
        verify(service, times(2)).commitMerged(eq(goodsId), aryEq(file), eq("v1:token"), eq(selected));
    }

    @Test void malformedOrMissingFilesNeverReachTheImportService() throws Exception {
        for (byte[] content : List.of("not-json".getBytes(java.nio.charset.StandardCharsets.UTF_8),
                new ObjectMapper().writeValueAsBytes(Map.of("stateFingerprint", "v1:token")))) {
            var error = assertThrows(ApiException.class, () -> controller.commitJson(goodsId, request(content)));
            assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        }
        verifyNoInteractions(service);
    }

    @Test void oversizedDecodedWorkbookAndOversizedSelectionsAreRejected() throws Exception {
        byte[] oversized = new byte[(int) GoodsImportWorkbookSecurity.MAX_COMPRESSED_BYTES + 1];
        var error = assertThrows(ApiException.class, () -> controller.commitJson(goodsId, request(
                new ObjectMapper().writeValueAsBytes(Map.of("file", oversized)))));
        assertEquals(ErrorCode.PAYLOAD_TOO_LARGE, error.getCode());
        var keys = java.util.stream.IntStream.range(0, 2001).mapToObj(i -> "row:" + i).toList();
        error = assertThrows(ApiException.class, () -> controller.commitJson(goodsId, request(
                new ObjectMapper().writeValueAsBytes(Map.of("file", new byte[]{1}, "replaceRowKeys", keys)))));
        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        verifyNoInteractions(service);
    }

    private MockHttpServletRequest request(byte[] content) {
        var request = new MockHttpServletRequest(); request.setContentType("application/json"); request.setContent(content); return request;
    }
}
