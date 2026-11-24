#include <assert.h>
#include <string.h>
#include "eos_codec.h"

static void put(uint8_t *p, uint32_t n)
{
    for (int i = 0; i < 4; i++) p[i] = n >> (8 * i);
}

int main(void)
{
    uint8_t data[52] = {0};
    put(data, 16); put(data + 4, 0xc189); put(data + 8, 0xd101); put(data + 12, 0x30);
    put(data + 16, 28); put(data + 20, 0xc18a); put(data + 24, 0xd101);
    put(data + 28, 3); put(data + 32, 2); put(data + 36, 0x30); put(data + 40, 0x38);
    put(data + 44, 8);
    eos_exposure_t state = {0};
    assert(eos_decode_events(data, sizeof(data), &state));
    assert(state.aperture.known && state.aperture.value == 0x30);
    assert(state.aperture.options_known && state.aperture.option_count == 2);
    assert(state.aperture.options[1] == 0x38 && !state.iso.known);
    assert(eos_property_allows(&state.aperture, 0x30));
    assert(!eos_property_allows(&state.aperture, 0xff));
    assert(!eos_property_allows(&state.iso, 0));
    assert(!eos_property_allows(NULL, 0));
    uint8_t encoded[24];
    assert(eos_encode_property(encoded, sizeof(encoded), 0x12345678, 0xd103, 0x58) == 24);
    const uint8_t expected[] = {24,0,0,0,2,0,0x10,0x91,0x78,0x56,0x34,0x12,12,0,0,0,3,0xd1,0,0,0x58,0,0,0};
    assert(!memcmp(encoded, expected, sizeof(expected)));
    assert(!eos_encode_property(encoded, 23, 1, 0xd103, 0));
    eos_exposure_t saved = state;
    for (size_t n = 1; n < sizeof(data); n++) {
        if (n == 16 || n == 44) continue; // Complete blocks without a terminator are valid.
        assert(!eos_decode_events(data, n, &state));
        assert(!memcmp(&saved, &state, sizeof(state)));
    }
    put(data + 12, 0x40); put(data + 32, 0xffffffff);
    assert(!eos_decode_events(data, sizeof(data), &state));
    assert(!memcmp(&saved, &state, sizeof(state))); // No partial updates on bad trailing record.
    put(data + 32, 2); put(data + 28, 7);
    assert(eos_decode_events(data, sizeof(data), &state));
    assert(!state.aperture.options_known && state.aperture.option_count == 0);
    put(data, 0);
    assert(!eos_decode_events(data, sizeof(data), &state));
    put(data, 0xffffffff);
    assert(!eos_decode_events(data, sizeof(data), &state));
    assert(!eos_decode_events(NULL, 0, &state));
    uint8_t focus[24] = {0};
    put(focus, 16); put(focus + 4, 0xc189); put(focus + 8, 0xd1ba); put(focus + 12, 9); put(focus + 16, 8);
    assert(eos_decode_events(focus, sizeof(focus), &state));
    assert(state.af_method.known && state.af_method.value == 9);
    assert(eos_property(&state, 0xd108) == &state.focus_mode);
    assert(eos_property(&state, 0xd179) == &state.movie_servo);
    assert(!eos_property(&state, 0xffff));
    uint8_t timer[52] = {0};
    put(timer, 16); put(timer + 4, 0xc189); put(timer + 8, 0xd114); put(timer + 12, 0);
    put(timer + 16, 28); put(timer + 20, 0xc18a); put(timer + 24, 0xd114);
    put(timer + 28, 3); put(timer + 32, 2); put(timer + 36, 0); put(timer + 40, 30);
    put(timer + 44, 8);
    assert(eos_decode_events(timer, sizeof(timer), &state));
    assert(state.power_off_known && state.power_off == 0);
    assert(state.auto_power_off.known && state.auto_power_off.value == 0);
    assert(eos_property_allows(&state.auto_power_off, 30));
    assert(eos_property_allows(&state.auto_power_off, 0));
    assert(!eos_property_allows(&state.auto_power_off, 60));
    uint8_t geometry[40] = {0};
    put(geometry, 32); put(geometry + 4, 0xc189); put(geometry + 8, 0xd1d3);
    put(geometry + 12, 20);
    put(geometry + 24, 6960 | (4640U << 16));
    put(geometry + 28, 1920 | (1080U << 16));
    put(geometry + 32, 8);
    assert(eos_decode_events(geometry, sizeof(geometry), &state));
    assert(state.focus_width == 6960 && state.focus_height == 4640);
    assert(state.focus_image_width == 1920 && state.focus_image_height == 1080);
    put(geometry + 12, 4096); // Invalid nested length must not create usable geometry.
    assert(eos_decode_events(geometry, sizeof(geometry), &state));
    assert(state.focus_width == 0 && state.focus_height == 0);
    uint8_t live[36] = {0};
    put(live, 16); put(live + 4, 0xe); put(live + 8, 6960); put(live + 12, 4640);
    put(live + 16, 20); put(live + 20, 1);
    const uint8_t jpeg[] = {0xff,0xd8,0xff,0xc0,0,8,8,4,0x38,7,0x80,0};
    memcpy(live + 24, jpeg, sizeof(jpeg));
    uint32_t w = 0, h = 0, jw = 0, jh = 0;
    assert(eos_decode_live_geometry(live, sizeof(live), &w, &h, &jw, &jh));
    assert(w == 6960 && h == 4640 && jw == 1920 && jh == 1080);
    for (size_t n = 0; n < sizeof(live); n++) {
        assert(!eos_decode_live_geometry(live, n, &w, &h, &jw, &jh));
        assert(w == 6960 && h == 4640 && jw == 1920 && jh == 1080);
    }
    put(live + 8, 100001);
    assert(!eos_decode_live_geometry(live, sizeof(live), &w, &h, &jw, &jh));
    put(live + 8, 6960); live[28] = 0xff;
    assert(!eos_decode_live_geometry(live, sizeof(live), &w, &h, &jw, &jh));
    return 0;
}
