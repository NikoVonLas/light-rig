#include "eos_codec.h"

static uint32_t u32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
        ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static bool jpeg_dimensions(const uint8_t *data, size_t length, uint32_t *width, uint32_t *height)
{
    if (length < 4 || data[0] != 0xff || data[1] != 0xd8) return false;
    size_t offset = 2;
    while (offset + 4 <= length) {
        if (data[offset++] != 0xff) return false;
        while (offset < length && data[offset] == 0xff) offset++;
        if (offset >= length) return false;
        uint8_t marker = data[offset++];
        if (marker == 0xda || marker == 0xd9) return false;
        if (offset + 2 > length) return false;
        size_t size = (data[offset] << 8) | data[offset + 1];
        if (size < 2 || size > length - offset) return false;
        if (marker == 0xc0 || marker == 0xc1 || marker == 0xc2) {
            if (size < 8) return false;
            *height = (data[offset + 3] << 8) | data[offset + 4];
            *width = (data[offset + 5] << 8) | data[offset + 6];
            return *width > 0 && *height > 0;
        }
        offset += size;
    }
    return false;
}

bool eos_decode_live_geometry(const uint8_t *bytes, size_t length, uint32_t *width, uint32_t *height,
                              uint32_t *jpeg_width, uint32_t *jpeg_height)
{
    if (!bytes || !width || !height || !jpeg_width || !jpeg_height) return false;
    uint32_t w = 0, h = 0, jw = 0, jh = 0;
    for (size_t offset = 0; offset < length;) {
        if (length - offset < 8) return false;
        uint32_t size = u32(bytes + offset), type = u32(bytes + offset + 4);
        if (size < 8 || size > length - offset) return false;
        if (type == 0xe && size >= 16) {
            w = u32(bytes + offset + 8); h = u32(bytes + offset + 12);
        }
        if (type == 1 || type == 0xb) jpeg_dimensions(bytes + offset + 8, size - 8, &jw, &jh);
        offset += size;
    }
    if (!w || !h || w > 100000 || h > 100000 || !jw || !jh) return false;
    *width = w; *height = h; *jpeg_width = jw; *jpeg_height = jh;
    return true;
}

eos_property_t *eos_property(eos_exposure_t *state, uint32_t code)
{
    switch (code) {
        case 0xd101: return &state->aperture;
        case 0xd102: return &state->shutter;
        case 0xd103: return &state->iso;
        case 0xd108: return &state->focus_mode;
        case 0xd1ba: return &state->af_method;
        case 0xd179: return &state->movie_servo;
        case 0xd114: return &state->auto_power_off;
        default: return NULL;
    }
}

bool eos_property_allows(const eos_property_t *property, uint32_t value)
{
    if (!property || !property->known || !property->options_known || property->option_count > EOS_OPTION_LIMIT) return false;
    for (uint32_t i = 0; i < property->option_count; i++) if (property->options[i] == value) return true;
    return false;
}

size_t eos_encode_property(uint8_t *output, size_t capacity, uint32_t transaction,
                           uint32_t property, uint32_t value)
{
    if (!output || capacity < 24) return 0;
    // PTP DATA header, followed by Canon's length/property/value record.
    uint32_t words[] = {24, 0x91100002, transaction, 12, property, value};
    for (size_t i = 0; i < 6; i++)
        for (size_t j = 0; j < 4; j++) output[i * 4 + j] = words[i] >> (8 * j);
    return 24;
}

bool eos_decode_events(const uint8_t *bytes, size_t length, eos_exposure_t *exposure)
{
    if (!bytes || !exposure) return false;
    eos_exposure_t next = *exposure;
    size_t offset = 0;
    while (offset < length) {
        if (length - offset < 8) return false;
        const uint8_t *p = bytes + offset;
        uint32_t size = u32(p), event = u32(p + 4);
        if (size < 8 || size > length - offset) return false;
        if (event == 0 && size == 8) {
            if (offset + 8 != length) return false;
            break;
        }
        if (event == 0xc189 || event == 0xc18a) {
            if (size < 12) return false;
            uint32_t code = u32(p + 8);
            if (event == 0xc189 && size >= 16) {
                if (code == 0xd114) { next.power_off_known = true; next.power_off = u32(p + 12); }
                if (code == 0xd1b0) { next.evf_output_known = true; next.evf_output = u32(p + 12); }
                if (code == 0xd1b1) { next.evf_mode_known = true; next.evf_mode = u32(p + 12); }
                if (code == 0xd1d3) {
                    next.focus_width = next.focus_height = next.focus_image_width = next.focus_image_height = 0;
                    if (size >= 32 && u32(p + 12) >= 20 && u32(p + 12) <= size - 12) {
                        next.focus_width = p[24] | (p[25] << 8);
                        next.focus_height = p[26] | (p[27] << 8);
                        next.focus_image_width = p[28] | (p[29] << 8);
                        next.focus_image_height = p[30] | (p[31] << 8);
                    }
                }
            }
            eos_property_t *property = eos_property(&next, code);
            if (property && event == 0xc189) {
                if (size < 16) return false;
                property->value = u32(p + 12);
                property->known = true;
            } else if (property) {
                if (size < 20) return false;
                uint32_t type = u32(p + 12), count = u32(p + 16);
                property->options_known = false;
                property->option_count = 0;
                if (type == 3) {
                    if (count > (size - 20) / 4 || count > EOS_OPTION_LIMIT) return false;
                    for (uint32_t i = 0; i < count; i++) property->options[i] = u32(p + 20 + 4 * i);
                    property->option_count = count;
                    property->options_known = true;
                }
            }
        }
        offset += size;
    }
    *exposure = next;
    return true;
}
