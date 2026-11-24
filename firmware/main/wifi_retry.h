#pragma once
#include <stdint.h>

static inline uint32_t rig_wifi_retry_delay_ms(unsigned failures)
{
    return failures >= 4 ? 30000 : 2000u << failures;
}
