#include <assert.h>
#include <limits.h>
#include "wifi_retry.h"

int main(void)
{
    assert(rig_wifi_retry_delay_ms(0) == 2000);
    assert(rig_wifi_retry_delay_ms(1) == 4000);
    for (unsigned i = 1; i < 1000; ++i) {
        assert(rig_wifi_retry_delay_ms(i) >= rig_wifi_retry_delay_ms(i - 1));
        assert(rig_wifi_retry_delay_ms(i) <= 30000);
    }
    assert(rig_wifi_retry_delay_ms(UINT_MAX) == 30000);
    // A successful connection resets the caller's failure counter.
    assert(rig_wifi_retry_delay_ms(0) == 2000);
}
