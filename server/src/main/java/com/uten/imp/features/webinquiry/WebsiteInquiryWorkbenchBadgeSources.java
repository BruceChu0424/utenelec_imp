package com.uten.imp.features.webinquiry;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import java.util.List;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
class WebsiteInquiryWorkbenchBadgeSources implements WorkbenchBadgeSources {
    private final WebsiteInquiryController controller;
    @Override public List<Source> sources() {
        return List.of(new Source("websiteInquiry",()->WorkbenchBadgeSources.numbers(controller.counts())));
    }
}
