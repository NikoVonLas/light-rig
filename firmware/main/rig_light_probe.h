#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    bool armed;
    bool captured;
    bool ws2812_like;
    size_t symbols;
    uint32_t minimum_ns;
    uint32_t maximum_ns;
} light_probe_result_t;

void rig_light_probe_init(void);
bool rig_light_probe_arm(void);
bool rig_light_probe_release(void);
light_probe_result_t rig_light_probe_get(void);
