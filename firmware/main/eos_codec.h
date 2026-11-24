#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define EOS_OPTION_LIMIT 128
typedef struct {
    bool known, options_known;
    uint32_t value, option_count;
    uint32_t options[EOS_OPTION_LIMIT];
} eos_property_t;
typedef struct {
    eos_property_t aperture, shutter, iso, focus_mode, af_method, movie_servo, auto_power_off;
    bool power_off_known, evf_output_known, evf_mode_known;
    uint32_t power_off, evf_output, evf_mode;
    uint16_t focus_width, focus_height, focus_image_width, focus_image_height;
} eos_exposure_t;
eos_property_t *eos_property(eos_exposure_t *state, uint32_t code);
bool eos_property_allows(const eos_property_t *property, uint32_t value);
size_t eos_encode_property(uint8_t *output, size_t capacity, uint32_t transaction,
                           uint32_t property, uint32_t value);

// Applies a complete event block atomically; ignores well-formed unrelated events.
bool eos_decode_events(const uint8_t *bytes, size_t length, eos_exposure_t *exposure);
bool eos_decode_live_geometry(const uint8_t *bytes, size_t length, uint32_t *width, uint32_t *height,
                              uint32_t *jpeg_width, uint32_t *jpeg_height);
