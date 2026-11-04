package com.uten.imp.features.applications;
import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
@Component
@RequiredArgsConstructor
class ApplicationWorkbenchBadgeSources implements WorkbenchBadgeSources {
    private final BusinessApplicationController controller;
    @Override public List<Source> sources(){return List.of(new Source("application",()->WorkbenchBadgeSources.numbers(controller.counts())));}
}
