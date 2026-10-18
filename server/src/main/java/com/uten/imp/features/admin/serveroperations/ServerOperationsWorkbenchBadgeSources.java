package com.uten.imp.features.admin.serveroperations;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.List;
import java.util.Map;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
class ServerOperationsWorkbenchBadgeSources implements WorkbenchBadgeSources {
    private final ServerOperationsController controller;
    @Override public List<Source> sources() {
        return List.of(new Source("serverOperations", () -> {
            var status = controller.status();
            if (!status.available()) {
                // A locally unsupported platform has no update task. A broken Linux helper remains stale.
                if (status.failure() != null
                        && ServerOperationFailures.HOST_PLATFORM_UNSUPPORTED.equals(status.failure().code())) {
                    return Map.of("updates", 0L);
                }
                throw new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE);
            }
            return Map.of("updates", status.canUpdate() && Boolean.TRUE.equals(status.updateAvailable()) ? 1L : 0L);
        }));
    }
}
