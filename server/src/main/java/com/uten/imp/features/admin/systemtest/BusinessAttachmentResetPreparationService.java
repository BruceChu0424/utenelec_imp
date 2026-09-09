package com.uten.imp.features.admin.systemtest;

import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort;
import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort.Confirmation;
import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort.Preview;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.util.UUID;

/** Shares the reset feature flag and drain window; the attachment feature owns the file intents. */
@Service
@RequiredArgsConstructor
public class BusinessAttachmentResetPreparationService {
    private final BusinessDataResetFeatureGate feature;
    private final BusinessDataResetDrainGate drain;
    private final BusinessAttachmentResetPreparationPort attachments;

    public Preview preview(UUID actor) {
        feature.requireEnabled();
        return attachments.preview(actor);
    }

    public Preview prepare(UUID actor, String account, Confirmation confirmation) {
        feature.requireEnabled();
        try {
            if (!drain.beginDrain(BusinessDataResetService.DRAIN_TIMEOUT_MILLIS)) {
                throw new ApiException(ErrorCode.CONFLICT, "仍有操作正在进行，请稍后重新预览");
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new ApiException(ErrorCode.CONFLICT, "等待中的文件准备已中断，请重试");
        }
        try { return attachments.prepare(actor, account, confirmation); }
        finally { drain.endReset(); }
    }
}
