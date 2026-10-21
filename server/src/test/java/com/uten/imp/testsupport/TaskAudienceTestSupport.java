package com.uten.imp.testsupport;

import com.uten.imp.application.port.TaskAudiencePort;

/** Unit harnesses which already supply source-level authority explicitly. */
public final class TaskAudienceTestSupport {
    private TaskAudienceTestSupport() {}
    public static TaskAudiencePort direct() {
        return new TaskAudiencePort() {
            @Override public <T> T read(com.uten.imp.application.port.TaskAudiencePort.ReadQuery<T> work) { return work.read(); }
            @Override public <T> T browsingRead(com.uten.imp.application.port.TaskAudiencePort.ReadQuery<T> work) { return work.read(); }
        };
    }
}
