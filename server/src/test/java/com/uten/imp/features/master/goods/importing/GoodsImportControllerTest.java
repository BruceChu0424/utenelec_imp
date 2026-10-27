package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.mock.web.MockHttpServletRequest;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Stream;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class GoodsImportControllerTest {

    @TempDir
    Path tempDirectory;

    @Test
    void readBoundedAcceptsKnownSafePayloadAndRemovesStagingFile() throws Exception {
        byte[] payload = new byte[]{1, 2, 3, 4};

        byte[] result = GoodsImportController.readBounded(
                new ByteArrayInputStream(payload), payload.length, payload.length, tempDirectory);

        assertArrayEquals(payload, result);
        assertTrue(isEmpty(tempDirectory));
    }

    @Test
    void readBoundedRejectsOversizedDeclaredLengthBeforeCreatingStagingFile() throws Exception {
        ApiException error = assertThrows(ApiException.class, () ->
                GoodsImportController.readBounded(
                        new ByteArrayInputStream(new byte[0]), 5, 4, tempDirectory));

        assertEquals(ErrorCode.PAYLOAD_TOO_LARGE, error.getCode());
        assertTrue(isEmpty(tempDirectory));
    }

    @Test
    void readBoundedStopsUnknownLengthPayloadAtTheHardLimitAndCleansUp() throws Exception {
        ApiException error = assertThrows(ApiException.class, () ->
                GoodsImportController.readBounded(
                        new ByteArrayInputStream(new byte[]{1, 2, 3, 4, 5}), -1, 4, tempDirectory));

        assertEquals(ErrorCode.PAYLOAD_TOO_LARGE, error.getCode());
        assertTrue(isEmpty(tempDirectory));
    }

    @Test
    void readBoundedCleansUpWhenTheRequestStreamFails() throws Exception {
        InputStream failingInput = new InputStream() {
            private int reads;

            @Override
            public int read() throws IOException {
                if (reads++ == 0) {
                    return 1;
                }
                throw new IOException("simulated client disconnect");
            }
        };

        assertThrows(IOException.class, () -> GoodsImportController.readBounded(
                failingInput, -1, 4, tempDirectory));
        assertTrue(isEmpty(tempDirectory));
    }

    @Test
    void controllerRejectsASecondConcurrentPoiImportAcrossSourceIps() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        CountDownLatch firstEnteredParser = new CountDownLatch(1);
        CountDownLatch releaseFirst = new CountDownLatch(1);
        when(service.detect(any())).thenAnswer(invocation -> {
            firstEnteredParser.countDown();
            assertTrue(releaseFirst.await(5, TimeUnit.SECONDS));
            return null;
        });

        MockHttpServletRequest firstRequest = new MockHttpServletRequest();
        firstRequest.setContent(new byte[]{1});
        AtomicReference<Throwable> firstFailure = new AtomicReference<>();
        Thread first = new Thread(() -> {
            try {
                controller.detect(firstRequest);
            } catch (Throwable error) {
                firstFailure.set(error);
            }
        });
        first.start();
        assertTrue(firstEnteredParser.await(5, TimeUnit.SECONDS));

        MockHttpServletRequest secondRequest = new MockHttpServletRequest();
        secondRequest.setContent(new byte[]{2});
        ApiException busy = assertThrows(ApiException.class, () -> controller.detect(secondRequest));
        assertEquals(ErrorCode.RATE_LIMITED, busy.getCode());

        releaseFirst.countDown();
        first.join(5_000);
        assertTrue(!first.isAlive());
        assertEquals(null, firstFailure.get());
    }

    @Test
    void commitForwardsRequiredPlanIdWithTheExactUploadedBytes() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        UUID planId = UUID.randomUUID();
        byte[] bytes = new byte[]{7, 8, 9};
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setContent(bytes);
        GoodsImportResult expected = new GoodsImportResult(
                UUID.randomUUID(), 1, 0, 0, 0, List.of());
        when(service.commit(eq(planId), any(), eq("goods.xlsx"))).thenReturn(expected);

        GoodsImportResult result = controller.commit(planId, "goods.xlsx", request);

        assertEquals(expected, result);
        org.mockito.Mockito.verify(service).commit(planId, bytes, "goods.xlsx");
    }

    @Test
    void jsonCommitKeepsA2000RowSelectionOutOfTheRequestUrl() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        UUID planId = UUID.randomUUID();
        byte[] bytes = new byte[]{7, 8, 9};
        List<String> keys = java.util.stream.IntStream.rangeClosed(2, 2001).mapToObj(n -> "goods:" + n).toList();
        var body = new GoodsImportCommitRequest(bytes, planId, "goods.xlsx", keys);
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setContentType("application/json");
        request.setContent(new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsBytes(body));

        controller.commitJson(request);

        org.mockito.Mockito.verify(service).commit(planId, bytes, "goods.xlsx", java.util.Set.copyOf(keys));
    }

    @Test
    void jsonCommitRejectsAnOversizedSelectionBeforeCallingTheService() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        var body = new GoodsImportCommitRequest(new byte[]{1}, UUID.randomUUID(), "goods.xlsx",
                java.util.stream.IntStream.rangeClosed(1, 2001).mapToObj(n -> "goods:" + n).toList());
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setContent(new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsBytes(body));

        assertThrows(ApiException.class, () -> controller.commitJson(request));
        org.mockito.Mockito.verifyNoInteractions(service);
    }

    @Test
    void jsonCommitRejectsMalformedBase64AndAlwaysReleasesTheImportSlot() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setContent("{\"file\":\"!invalid!\"}".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        assertThrows(ApiException.class, () -> controller.commitJson(request));
        MockHttpServletRequest valid = new MockHttpServletRequest(); valid.setContent(new byte[]{1});
        controller.detect(valid);
        org.mockito.Mockito.verify(service).detect(new byte[]{1});
    }

    @Test
    void jsonDetectForwardsCorrectionsWithTheExactOriginalWorkbookBytes() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        byte[] bytes = new byte[]{7, 8, 9};
        Map<Integer, String> corrections = Map.of(2, "NEW001", 3, "");
        var request = jsonRequest(new GoodsImportDetectRequest(bytes, corrections));

        controller.detectJson(request);

        org.mockito.Mockito.verify(service).detect(bytes, corrections, null);
    }

    @Test
    void jsonDetectWithoutCorrectionsRetainsTheLegacyServiceContract() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        byte[] bytes = new byte[]{7, 8, 9};

        controller.detectJson(jsonRequest(new GoodsImportDetectRequest(bytes, null)));

        org.mockito.Mockito.verify(service).detect(bytes);
        org.mockito.Mockito.verify(service, org.mockito.Mockito.never()).detect(any(), any());
        org.mockito.Mockito.verify(service, org.mockito.Mockito.never()).detect(any(), any(), any());
        org.mockito.Mockito.verify(service, org.mockito.Mockito.never()).detect(any(), any(), any(), any());
    }

    @Test
    void jsonCommitForwardsTheSameCorrectionsAndReviewSelection() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        UUID planId = UUID.randomUUID();
        byte[] bytes = new byte[]{7, 8, 9};
        Map<Integer, String> corrections = Map.of(2, "NEW001", 3, "");

        controller.commitJson(jsonRequest(new GoodsImportCommitRequest(
                bytes, planId, "goods.xlsx", List.of("goods:2"), corrections)));

        org.mockito.Mockito.verify(service).commit(planId, bytes, "goods.xlsx", java.util.Set.of("goods:2"), corrections, null);
    }

    @Test
    void detectHttpMappingsKeepRawUploadsAndCorrectionJsonSeparate() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        var mvc = org.springframework.test.web.servlet.setup.MockMvcBuilders
                .standaloneSetup(new GoodsImportController(service)).build();
        byte[] bytes = new byte[]{7, 8, 9};
        Map<Integer, String> corrections = Map.of(2, "NEW001");

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders
                .post("/api/master/goods/import/detect").contentType("application/octet-stream").content(bytes))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.status().isOk());
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders
                .post("/api/master/goods/import/detect").contentType("application/json")
                .content(new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsBytes(
                        new GoodsImportDetectRequest(bytes, corrections))))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.status().isOk());

        org.mockito.Mockito.verify(service).detect(bytes);
        org.mockito.Mockito.verify(service).detect(bytes, corrections, null);
    }

    @Test
    void jsonEndpointsRejectMalformedCorrectionKeysAndDuplicateKeysBeforeServiceCalls() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        for (String invalidCorrections : List.of(
                "{\"not-a-row\":\"NEW001\"}", "{\"2147483648\":\"NEW001\"}",
                "{\"2\":\"NEW001\",\"02\":\"OTHER001\"}", "{\"+2\":\"NEW001\"}",
                "{\" 2\":\"NEW001\"}", "{\"0\":\"NEW001\"}",
                "{\"2\":\"NEW001\",\"2\":\"OTHER001\"}")) {
            String json = "{\"file\":\"AQ==\",\"codeCorrections\":" + invalidCorrections + "}";
            ApiException detected = assertThrows(ApiException.class,
                    () -> controller.detectJson(jsonRequest(json)));
            assertEquals(ErrorCode.VALIDATION_FAILED, detected.getCode());
            String commitJson = "{\"file\":\"AQ==\",\"planId\":\"" + UUID.randomUUID()
                    + "\",\"codeCorrections\":" + invalidCorrections + "}";
            ApiException committed = assertThrows(ApiException.class,
                    () -> controller.commitJson(jsonRequest(commitJson)));
            assertEquals(ErrorCode.VALIDATION_FAILED, committed.getCode());
        }
        org.mockito.Mockito.verifyNoInteractions(service);
        MockHttpServletRequest valid = new MockHttpServletRequest(); valid.setContent(new byte[]{1});
        controller.detect(valid);
        org.mockito.Mockito.verify(service).detect(new byte[]{1});
    }

    @Test
    void jsonEndpointsForwardExcludedRowsWithTheSameOriginalBytes() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        byte[] bytes = new byte[]{7, 8, 9};
        UUID planId = UUID.randomUUID();
        java.util.Set<Integer> excluded = java.util.Set.of(2, 4);

        controller.detectJson(jsonRequest(new GoodsImportDetectRequest(bytes, Map.of(), excluded)));
        controller.commitJson(jsonRequest(new GoodsImportCommitRequest(
                bytes, planId, "goods.xlsx", List.of(), Map.of(), excluded)));

        org.mockito.Mockito.verify(service).detect(bytes, Map.of(), excluded);
        org.mockito.Mockito.verify(service).commit(planId, bytes, "goods.xlsx", java.util.Set.of(), Map.of(), excluded);
    }

    @Test
    void jsonEndpointsForwardCellCorrectionsWithTheOriginalWorkbookAndOtherSelections() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        byte[] bytes = new byte[]{7, 8, 9};
        UUID planId = UUID.randomUUID();
        Map<Integer, String> codes = Map.of(2, "NEW001");
        java.util.Set<Integer> excluded = java.util.Set.of(4);
        Map<Integer, Map<String, String>> cells = Map.of(2, Map.of("name", "修正名称", "price", "12.3400"));

        controller.detectJson(jsonRequest(new GoodsImportDetectRequest(bytes, codes, excluded, cells)));
        controller.commitJson(jsonRequest(new GoodsImportCommitRequest(
                bytes, planId, "goods.xlsx", List.of("goods:2"), codes, excluded, cells)));

        org.mockito.Mockito.verify(service).detect(bytes, codes, excluded, cells);
        org.mockito.Mockito.verify(service).commit(planId, bytes, "goods.xlsx", java.util.Set.of("goods:2"), codes, excluded, cells);
    }

    @Test
    void emptyCellCorrectionsRetainTheLegacyDetectionAndCommitContracts() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        byte[] bytes = new byte[]{7, 8, 9};
        UUID planId = UUID.randomUUID();

        controller.detectJson(jsonRequest(new GoodsImportDetectRequest(bytes, Map.of(), java.util.Set.of(), Map.of())));
        controller.commitJson(jsonRequest(new GoodsImportCommitRequest(
                bytes, planId, "goods.xlsx", List.of(), Map.of(), java.util.Set.of(), Map.of())));

        org.mockito.Mockito.verify(service).detect(bytes);
        org.mockito.Mockito.verify(service).commit(planId, bytes, "goods.xlsx", java.util.Set.of());
    }

    @Test
    void jsonEndpointsRejectCellRowAliasesAndNonStringCellValuesBeforeTheService() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        for (String invalidCells : List.of(
                "[]", "{\"2\":null}", "{\"2\":[]}", "{\"2\":{\"price\":1}}",
                "{\"2\":{\"status\":true}}", "{\"2\":{\"name\":null}}", "{\"2\":{\"name\":{}}}",
                "{\"02\":{\"name\":\"x\"}}", "{\"2147483648\":{\"name\":\"x\"}}",
                "{\"2\":{\"name\":\"x\"},\"02\":{\"name\":\"y\"}}",
                "{\"2\":{\"name\":\"x\",\"name\":\"y\"}}")) {
            String json = "{\"file\":\"AQ==\",\"cellCorrections\":" + invalidCells + "}";
            assertEquals(ErrorCode.VALIDATION_FAILED, assertThrows(ApiException.class,
                    () -> controller.detectJson(jsonRequest(json))).getCode());
            String commitJson = "{\"file\":\"AQ==\",\"planId\":\"" + UUID.randomUUID()
                    + "\",\"cellCorrections\":" + invalidCells + "}";
            assertEquals(ErrorCode.VALIDATION_FAILED, assertThrows(ApiException.class,
                    () -> controller.commitJson(jsonRequest(commitJson))).getCode());
        }
        org.mockito.Mockito.verifyNoInteractions(service);
        controller.detectJson(jsonRequest(new GoodsImportDetectRequest(new byte[]{1}, Map.of())));
        org.mockito.Mockito.verify(service).detect(new byte[]{1});
    }

    @Test
    void jsonEndpointsRejectNonIntegerNullAndRepeatedExcludedRowsBeforeTheService() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        for (String invalidRows : List.of("[\"2\"]", "[2.0]", "[null]", "[2,2]", "{}", "[2147483648]", "[true]")) {
            String json = "{\"file\":\"AQ==\",\"excludedRowNums\":" + invalidRows + "}";
            assertEquals(ErrorCode.VALIDATION_FAILED, assertThrows(ApiException.class,
                    () -> controller.detectJson(jsonRequest(json))).getCode());
            String commitJson = "{\"file\":\"AQ==\",\"planId\":\"" + UUID.randomUUID()
                    + "\",\"excludedRowNums\":" + invalidRows + "}";
            assertEquals(ErrorCode.VALIDATION_FAILED, assertThrows(ApiException.class,
                    () -> controller.commitJson(jsonRequest(commitJson))).getCode());
        }
        org.mockito.Mockito.verifyNoInteractions(service);
        controller.detectJson(jsonRequest(new GoodsImportDetectRequest(new byte[]{1}, Map.of(), java.util.Set.of())));
        org.mockito.Mockito.verify(service).detect(new byte[]{1});
    }

    @Test
    void jsonDetectRejectsMalformedBase64OrMissingFilesAndReleasesTheSlot() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        for (String invalidJson : List.of("{\"file\":\"!invalid!\"}", "{}", "{\"file\":\"\"}", "null")) {
            ApiException error = assertThrows(ApiException.class,
                    () -> controller.detectJson(jsonRequest(invalidJson)));
            assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        }
        org.mockito.Mockito.verifyNoInteractions(service);
        MockHttpServletRequest valid = new MockHttpServletRequest(); valid.setContent(new byte[]{1});
        controller.detect(valid);
        org.mockito.Mockito.verify(service).detect(new byte[]{1});
    }

    @Test
    void jsonEndpointsRejectEncodedBodiesOverFifteenMiBBeforeParsing() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        MockHttpServletRequest oversized = new MockHttpServletRequest() {
            @Override public long getContentLengthLong() { return 15L * 1024 * 1024 + 1; }
        };
        oversized.setContentType("application/json");
        oversized.setContent(new byte[0]);

        assertEquals(ErrorCode.PAYLOAD_TOO_LARGE,
                assertThrows(ApiException.class, () -> controller.detectJson(oversized)).getCode());
        assertEquals(ErrorCode.PAYLOAD_TOO_LARGE,
                assertThrows(ApiException.class, () -> controller.commitJson(oversized)).getCode());
        org.mockito.Mockito.verifyNoInteractions(service);
    }

    @Test
    void jsonEndpointsRejectDecodedFilesOverTenMiBBeforeCallingTheParser() throws Exception {
        GoodsImportService service = mock(GoodsImportService.class);
        GoodsImportController controller = new GoodsImportController(service);
        byte[] oversized = new byte[GoodsImportWorkbookSecurity.MAX_COMPRESSED_BYTES + 1];

        assertEquals(ErrorCode.PAYLOAD_TOO_LARGE, assertThrows(ApiException.class,
                () -> controller.detectJson(jsonRequest(new GoodsImportDetectRequest(oversized, Map.of())))).getCode());
        assertEquals(ErrorCode.PAYLOAD_TOO_LARGE, assertThrows(ApiException.class,
                () -> controller.commitJson(jsonRequest(new GoodsImportCommitRequest(
                        oversized, UUID.randomUUID(), "too-large.xlsx", List.of(), Map.of())))).getCode());
        org.mockito.Mockito.verifyNoInteractions(service);
    }

    private static MockHttpServletRequest jsonRequest(Object body) throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setContentType("application/json");
        request.setContent(new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsBytes(body));
        return request;
    }

    private static MockHttpServletRequest jsonRequest(String json) {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setContentType("application/json");
        request.setContent(json.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        return request;
    }

    private static boolean isEmpty(Path directory) throws IOException {
        try (Stream<Path> files = Files.list(directory)) {
            return files.findAny().isEmpty();
        }
    }
}
