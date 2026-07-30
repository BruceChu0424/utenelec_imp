package com.uten.imp.features.master.client.dto;

import java.util.UUID;

/**
 * 客户轻量字典项。
 *
 * <p>Includes identity/display fields and a flag for use in new documents.
 * Contact, bank, tax and credit fields must never be exposed by this bulk endpoint.
 */
public record ClientDictItem(UUID id, String code, String name, boolean selectable) {
}
