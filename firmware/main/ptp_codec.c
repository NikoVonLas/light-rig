#include "ptp_codec.h"
#include <string.h>

static uint16_t read_le16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t read_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void write_le16(uint8_t *p, uint16_t value)
{
    p[0] = value & 0xff;
    p[1] = value >> 8;
}

static bool info_string(const uint8_t **p, size_t *left, char *out, size_t capacity)
{
    if (!*left) return false;
    size_t units = *(*p)++;
    --*left;
    if (units > *left / 2) return false;
    if (units && read_le16(*p + (units - 1) * 2) != 0) return false;
    size_t written = 0;
    for (size_t i = 0; out && i + 1 < units; i++) {
        uint16_t c = read_le16(*p + i * 2);
        if (written + 1 < capacity) out[written++] = c < 128 ? (char)c : '?';
    }
    if (out && capacity) out[written] = 0;
    *p += units * 2;
    *left -= units * 2;
    return true;
}

static bool info_array(const uint8_t **p, size_t *left, uint32_t *count)
{
    if (*left < 4) return false;
    uint32_t n = read_le32(*p);
    *p += 4; *left -= 4;
    if (n > *left / 2) return false;
    if (count) *count = n;
    *p += n * 2; *left -= n * 2;
    return true;
}

bool ptp_decode_device_info(const uint8_t *bytes, size_t count, ptp_device_info_t *info)
{
    if (!bytes || !info || count < 8) return false;
    memset(info, 0, sizeof(*info));
    const uint8_t *p = bytes + 8;
    size_t left = count - 8;
    if (!info_string(&p, &left, NULL, 0) || left < 2) return false;
    p += 2; left -= 2;
    return info_array(&p, &left, &info->operation_count) &&
        info_array(&p, &left, &info->event_count) &&
        info_array(&p, &left, &info->property_count) &&
        info_array(&p, &left, NULL) && info_array(&p, &left, NULL) &&
        info_string(&p, &left, info->manufacturer, sizeof(info->manufacturer)) &&
        info_string(&p, &left, info->model, sizeof(info->model)) &&
        info_string(&p, &left, info->version, sizeof(info->version)) &&
        info_string(&p, &left, NULL, 0);
}

static void write_le32(uint8_t *p, uint32_t value)
{
    p[0] = value & 0xff;
    p[1] = (value >> 8) & 0xff;
    p[2] = (value >> 16) & 0xff;
    p[3] = (value >> 24) & 0xff;
}

bool ptp_device_supports_operation(const uint8_t *bytes, size_t count, uint16_t operation)
{
    if (!bytes || count < 8) return false;
    const uint8_t *p = bytes + 8;
    size_t left = count - 8;
    if (!info_string(&p, &left, NULL, 0) || left < 6) return false;
    p += 2; left -= 2;
    uint32_t n = read_le32(p);
    p += 4; left -= 4;
    if (n > left / 2) return false;
    for (uint32_t i = 0; i < n; i++) if (read_le16(p + 2 * i) == operation) return true;
    return false;
}

bool ptp_decode_header(const uint8_t *bytes, size_t count, ptp_container_header_t *header)
{
    if (!bytes || !header || count < 12) return false;
    header->length = read_le32(bytes);
    header->type = read_le16(bytes + 4);
    header->code = read_le16(bytes + 6);
    header->transaction_id = read_le32(bytes + 8);
    return header->length >= 12 && header->length <= count;
}

size_t ptp_encode_command(uint8_t *output, size_t capacity, uint16_t operation,
                          uint32_t transaction_id, const uint32_t *parameters,
                          size_t parameter_count)
{
    if (!output || parameter_count > 5 || (parameter_count && !parameters)) return 0;
    size_t length = 12 + parameter_count * 4;
    if (capacity < length) return 0;
    write_le32(output, (uint32_t)length);
    write_le16(output + 4, PTP_CONTAINER_COMMAND);
    write_le16(output + 6, operation);
    write_le32(output + 8, transaction_id);
    for (size_t i = 0; i < parameter_count; i++) {
        write_le32(output + 12 + i * 4, parameters[i]);
    }
    return length;
}
