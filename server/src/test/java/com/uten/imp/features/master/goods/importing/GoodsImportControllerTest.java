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

    private static boolean isEmpty(Path directory) throws IOException {
        try (Stream<Path> files = Files.list(directory)) {
            return files.findAny().isEmpty();
        }
    }
}
