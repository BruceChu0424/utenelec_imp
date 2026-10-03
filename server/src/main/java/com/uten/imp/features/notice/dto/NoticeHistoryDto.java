package com.uten.imp.features.notice.dto;

import com.fasterxml.jackson.annotation.JsonUnwrapped;
import java.time.Instant;
import java.util.UUID;

/** Personal removal never invents a new business status or widens the audience. */
public record NoticeHistoryDto(@JsonUnwrapped NoticeDto document,boolean deleted,Instant deletedAt,
        UUID deletedBy,String deletedByName,String deletedReason,boolean historyReadOnly){}
