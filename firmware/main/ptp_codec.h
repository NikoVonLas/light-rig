#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
    PTP_CONTAINER_COMMAND = 1,
    PTP_CONTAINER_DATA = 2,
    PTP_CONTAINER_RESPONSE = 3,
    PTP_CONTAINER_EVENT = 4,
};

typedef struct {
    uint32_t length;
    uint16_t type;
    uint16_t code;
    uint32_t transaction_id;
} ptp_container_header_t;

typedef struct {
    char manufacturer[64], model[64], version[32];
    uint32_t operation_count, event_count, property_count;
} ptp_device_info_t;
bool ptp_decode_device_info(const uint8_t *bytes, size_t count, ptp_device_info_t *info);
bool ptp_device_supports_operation(const uint8_t *bytes, size_t count, uint16_t operation);

bool ptp_decode_header(const uint8_t *bytes, size_t count, ptp_container_header_t *header);
size_t ptp_encode_command(uint8_t *output, size_t capacity, uint16_t operation,
                          uint32_t transaction_id, const uint32_t *parameters,
                          size_t parameter_count);
