package com.uten.imp.testsupport;

import com.uten.imp.application.port.TaskAudiencePort;
import java.util.function.Supplier;

/** Unit harnesses which already supply source-level authority explicitly. */
public final class TaskAudienceTestSupport {
    private TaskAudienceTestSupport() {}
    public static TaskAudiencePort direct() {
        return new TaskAudiencePort() {
            @Override public <T> T read(Supplier<T> work) { return work.get(); }
            @Override public <T> T browsingRead(Supplier<T> work) { return work.get(); }
        };
    }
}
