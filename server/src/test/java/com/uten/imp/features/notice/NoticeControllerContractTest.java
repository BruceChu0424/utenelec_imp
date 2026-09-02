package com.uten.imp.features.notice;

import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;

import java.lang.reflect.Method;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class NoticeControllerContractTest {

    @Test
    void arrivalsEndpointRequiresNoticeReadAndDelegatesCursor() throws Exception {
        Method endpoint = NoticeController.class.getMethod(
                "arrivals", Instant.class, UUID.class, int.class);
        assertArrayEquals(
                new String[]{"/arrivals"},
                endpoint.getAnnotation(GetMapping.class).value());
        assertEquals(
                "hasAuthority('notice:read')",
                endpoint.getAnnotation(PreAuthorize.class).value());

        RequestParam after = endpoint.getParameters()[0]
                .getAnnotation(RequestParam.class);
        RequestParam afterId = endpoint.getParameters()[1]
                .getAnnotation(RequestParam.class);
        RequestParam limit = endpoint.getParameters()[2]
                .getAnnotation(RequestParam.class);
        assertEquals("after", after.name());
        assertEquals(false, after.required());
        assertEquals(false, afterId.required());
        assertEquals("100", limit.defaultValue());

        NoticeService service = mock(NoticeService.class);
        NoticeService.ArrivalPage page = new NoticeService.ArrivalPage(
                List.of(),
                Instant.parse("2026-08-22T00:00:00Z"),
                UUID.randomUUID(),
                false);
        when(service.arrivals(null, null, 37)).thenReturn(page);
        NoticeController controller = new NoticeController(
                service,
                mock(NoticeAudienceService.class),
                mock(com.uten.imp.security.SecurityContextCurrentUser.class));

        NoticeService.ArrivalPage response = controller.arrivals(null, null, 37);

        assertEquals(page, response);
        verify(service).arrivals(null, null, 37);
    }

    @Test
    void popupAcknowledgementRequiresNoticeReadAndDelegatesToService()
            throws Exception {
        Method endpoint = NoticeController.class.getMethod(
                "acknowledgePopup", UUID.class);
        assertArrayEquals(
                new String[]{"/{id}/popup-ack"},
                endpoint.getAnnotation(PostMapping.class).value());
        assertEquals(
                "hasAuthority('notice:read')",
                endpoint.getAnnotation(PreAuthorize.class).value());

        NoticeService service = mock(NoticeService.class);
        NoticeController controller = new NoticeController(
                service,
                mock(NoticeAudienceService.class),
                mock(com.uten.imp.security.SecurityContextCurrentUser.class));
        UUID noticeId = UUID.randomUUID();

        controller.acknowledgePopup(noticeId);

        verify(service).acknowledgePopup(noticeId);
    }

    @Test
    void readByRouteRequiresNoticeReadAndReturnsCount() throws Exception {
        Method endpoint = NoticeController.class.getMethod(
                "markReadByRoute", List.class);
        assertArrayEquals(
                new String[]{"/read-by-route"},
                endpoint.getAnnotation(PostMapping.class).value());
        assertEquals(
                "hasAuthority('notice:read')",
                endpoint.getAnnotation(PreAuthorize.class).value());

        NoticeService service = mock(NoticeService.class);
        List<String> routes = List.of("/purchase/orders/" + UUID.randomUUID());
        when(service.markReadByRoutes(routes)).thenReturn(2);
        NoticeController controller = new NoticeController(
                service,
                mock(NoticeAudienceService.class),
                mock(com.uten.imp.security.SecurityContextCurrentUser.class));

        assertEquals(2, controller.markReadByRoute(routes).get("read"));
        verify(service).markReadByRoutes(routes);
    }
}
