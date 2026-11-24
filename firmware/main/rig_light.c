#include "rig_light.h"

#include <stdio.h>
#include <string.h>
#include "driver/gpio.h"
#include "driver/rmt_encoder.h"
#include "driver/rmt_tx.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "nvs.h"
#include "rig_light_probe.h"
#include "rig_state.h"

#define LIGHT_PRESET_COUNT 6
#define LIGHT_PRESET_MAGIC 0x4c505231U
#define LIGHT_NVS_NAMESPACE "light_presets"
// T8 ESP32-S2 V1.1 header IO17 drives the WS2812B DIN input.
// IO17 is not shared with the display, SD card, USB host, or CH340 UART.
#define LIGHT_RGB_GPIO GPIO_NUM_17
#define LIGHT_RGB_PIXELS 55
#define LIGHT_RMT_RESOLUTION_HZ 20000000U

typedef struct {
    uint32_t magic;
    char name[20];
    light_command_t command;
} stored_preset_t;

static const char *TAG = "rig_light";
static SemaphoreHandle_t s_lock;
static light_command_t s_command;
static light_frame_t s_frame;
static stored_preset_t s_presets[LIGHT_PRESET_COUNT];
static uint8_t s_active_preset;
static rmt_channel_handle_t s_rgb_channel;
static rmt_encoder_handle_t s_rgb_encoder;
static bool s_rgb_ready;
static uint32_t s_tx_frames;
static light_frame_t s_last_tx;
// Send boot OFF and let an explicit command refresh a separately powered strip.
static bool s_refresh_pending = true;

// Each RMT tick is 50 ns. Both symbols last 1.25 us (800 kbit/s).
static const rmt_symbol_word_t s_ws2812_zero = {
    .level0 = 1, .duration0 = 7, .level1 = 0, .duration1 = 18,
};
static const rmt_symbol_word_t s_ws2812_one = {
    .level0 = 1, .duration0 = 13, .level1 = 0, .duration1 = 12,
};
static const rmt_symbol_word_t s_ws2812_reset = {
    .level0 = 0, .duration0 = 3200, .level1 = 0, .duration1 = 3200,
};

RMT_ENCODER_FUNC_ATTR
static size_t encode_ws2812(const void *data, size_t data_size,
                            size_t symbols_written, size_t symbols_free,
                            rmt_symbol_word_t *symbols, bool *done, void *arg)
{
    (void)arg;
    if (data_size != 3) {
        *done = true;
        return 0;
    }
    const size_t bits = 24;
    const size_t data_symbols = LIGHT_RGB_PIXELS * bits;
    const size_t total = data_symbols + 1;
    size_t out = 0;
    while (out < symbols_free && symbols_written + out < total) {
        size_t position = symbols_written + out;
        size_t bit = position % bits;
        if (position == data_symbols) {
            symbols[out] = s_ws2812_reset;
        } else {
            uint8_t value = ((const uint8_t *)data)[bit / 8];
            symbols[out] = (value & (0x80U >> (bit % 8))) ? s_ws2812_one : s_ws2812_zero;
        }
        out++;
    }
    *done = symbols_written + out == total;
    return out;
}

static esp_err_t init_rgb_output(void)
{
    if (s_rgb_channel && s_rgb_encoder) return ESP_OK;
    if (!rig_light_probe_release()) return ESP_ERR_INVALID_STATE;

    const rmt_tx_channel_config_t channel_config = {
        .gpio_num = LIGHT_RGB_GPIO,
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = LIGHT_RMT_RESOLUTION_HZ,
        .mem_block_symbols = 128,
        .trans_queue_depth = 2,
        .flags.init_level = 0,
    };
    esp_err_t error = rmt_new_tx_channel(&channel_config, &s_rgb_channel);
    if (error != ESP_OK) return error;

    // Keep DATA biased toward ground when the output is not actively driving.
    // Do not reset the GPIO or change its direction here: RMT owns its matrix route.
    error = gpio_set_pull_mode(LIGHT_RGB_GPIO, GPIO_PULLDOWN_ONLY);
    if (error == ESP_OK) {
        light_output_status_t output = rig_light_get_output_status();
        if (!output.valid || !output.pull_down || output.pull_up) error = ESP_ERR_INVALID_STATE;
    }

    const rmt_simple_encoder_config_t encoder_config = {
        .callback = encode_ws2812,
        .min_chunk_size = 1,
    };
    if (error == ESP_OK) error = rmt_new_simple_encoder(&encoder_config, &s_rgb_encoder);
    if (error == ESP_OK) error = rmt_enable(s_rgb_channel);
    if (error != ESP_OK) {
        if (s_rgb_encoder) rmt_del_encoder(s_rgb_encoder);
        if (s_rgb_channel) rmt_del_channel(s_rgb_channel);
        s_rgb_encoder = NULL;
        s_rgb_channel = NULL;
        return error;
    }
    return ESP_OK;
}

static esp_err_t send_rgb(uint8_t red, uint8_t green, uint8_t blue)
{
    const uint8_t frame[] = {green, red, blue};
    const rmt_transmit_config_t config = {
        .loop_count = 0,
        .flags.eot_level = 0,
    };
    esp_err_t error = rmt_transmit(s_rgb_channel, s_rgb_encoder, frame, sizeof(frame), &config);
    if (error != ESP_OK) return error;
    error = rmt_tx_wait_all_done(s_rgb_channel, -1);
    if (error == ESP_OK) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        s_tx_frames++;
        s_last_tx = (light_frame_t){.red = red, .green = green, .blue = blue};
        xSemaphoreGive(s_lock);
    }
    return error;
}

static uint8_t scale8(uint8_t value, uint8_t percent)
{
    return (uint16_t)value * percent / 100U;
}

static light_command_t default_command(uint8_t slot)
{
    static const light_command_t defaults[LIGHT_PRESET_COUNT] = {
        {.enabled=true, .mode=LIGHT_WHITE_NEUTRAL, .brightness=70, .warm=65, .cool=65, .speed=40, .effect=LIGHT_EFFECT_SOLID},
        {.enabled=true, .mode=LIGHT_WHITE_WARM, .brightness=55, .warm=100, .cool=15, .speed=40, .effect=LIGHT_EFFECT_SOLID},
        {.enabled=true, .mode=LIGHT_WHITE_COOL, .brightness=65, .warm=15, .cool=100, .speed=40, .effect=LIGHT_EFFECT_SOLID},
        {.enabled=true, .mode=LIGHT_RGB, .brightness=45, .red=255, .green=120, .blue=35, .speed=35, .effect=LIGHT_EFFECT_SOLID},
        {.enabled=true, .mode=LIGHT_RGB, .brightness=45, .red=40, .green=90, .blue=255, .speed=30, .effect=LIGHT_EFFECT_BREATHE},
        {.enabled=true, .mode=LIGHT_RGB, .brightness=40, .red=255, .speed=35, .effect=LIGHT_EFFECT_RAINBOW},
    };
    return defaults[slot < LIGHT_PRESET_COUNT ? slot : 0];
}

static void init_presets(void)
{
    static const char *names[LIGHT_PRESET_COUNT] = {
        "Call neutral", "Warm", "Cool", "Sunset", "Breathe", "Rainbow"
    };
    nvs_handle_t nvs;
    bool nvs_ready = nvs_open(LIGHT_NVS_NAMESPACE, NVS_READONLY, &nvs) == ESP_OK;
    for (uint8_t slot = 0; slot < LIGHT_PRESET_COUNT; slot++) {
        stored_preset_t preset = {.magic = LIGHT_PRESET_MAGIC, .command = default_command(slot)};
        strlcpy(preset.name, names[slot], sizeof(preset.name));
        if (nvs_ready) {
            char key[4];
            snprintf(key, sizeof(key), "p%u", slot);
            size_t size = sizeof(preset);
            stored_preset_t saved;
            if (nvs_get_blob(nvs, key, &saved, &size) == ESP_OK &&
                size == sizeof(saved) && saved.magic == LIGHT_PRESET_MAGIC) preset = saved;
        }
        s_presets[slot] = preset;
    rig_state_note_activity();
    }
    if (nvs_ready) nvs_close(nvs);
}

static light_frame_t color_wheel(uint8_t position)
{
    light_frame_t frame = {0};
    if (position < 85) {
        frame.red = 255 - position * 3;
        frame.green = position * 3;
    } else if (position < 170) {
        position -= 85;
        frame.green = 255 - position * 3;
        frame.blue = position * 3;
    } else {
        position -= 170;
        frame.blue = 255 - position * 3;
        frame.red = position * 3;
    }
    return frame;
}

static light_frame_t render_frame(const light_command_t *command, uint32_t tick)
{
    light_frame_t frame = {0};
    if (!command->enabled) return frame;
    uint8_t level = command->brightness;
    uint32_t period = 220U - (uint32_t)command->speed * 2U;
    if (period < 20) period = 20;
    if (command->effect == LIGHT_EFFECT_BREATHE) {
        uint32_t phase = tick % period;
        uint8_t triangle = phase < period / 2 ? (phase * 200U / period) : ((period - phase) * 200U / period);
        level = (uint16_t)level * (25U + triangle) / 125U;
    }
    if (command->mode == LIGHT_RGB) {
        if (command->effect == LIGHT_EFFECT_RAINBOW) {
            frame = color_wheel((tick * (1U + command->speed / 12U)) & 0xff);
        } else if (command->effect == LIGHT_EFFECT_COLOR_CYCLE) {
            frame = color_wheel(((tick / (period / 8U + 1U)) * 32U) & 0xff);
        } else {
            frame.red = command->red;
            frame.green = command->green;
            frame.blue = command->blue;
        }
        frame.red = scale8(frame.red, level);
        frame.green = scale8(frame.green, level);
        frame.blue = scale8(frame.blue, level);
    } else {
        frame.warm = scale8(command->warm, level);
        frame.cool = scale8(command->cool, level);
    }
    return frame;
}

static void light_task(void *argument)
{
    (void)argument;
    uint32_t tick = 0;
    while (true) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        s_frame = render_frame(&s_command, tick++);
        light_frame_t frame = s_frame;
        bool transmit = s_rgb_ready && (s_refresh_pending || frame.red != s_last_tx.red ||
                        frame.green != s_last_tx.green || frame.blue != s_last_tx.blue);
        s_refresh_pending = false;
        xSemaphoreGive(s_lock);
        if (transmit) {
            esp_err_t error = send_rgb(frame.red, frame.green, frame.blue);
            if (error != ESP_OK) {
                ESP_LOGE(TAG, "RGB output failed: %s", esp_err_to_name(error));
                xSemaphoreTake(s_lock, portMAX_DELAY);
                s_rgb_ready = false;
                xSemaphoreGive(s_lock);
                rig_state_set_light(false, 0, UINT8_MAX, "error");
                rig_state_set_test("RGB TX ERROR");
            }
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}

void rig_light_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    init_presets();
    s_command = (light_command_t){.enabled=false, .mode=LIGHT_RGB,
        .brightness=15, .speed=30, .effect=LIGHT_EFFECT_SOLID};
    s_active_preset = UINT8_MAX;
    esp_err_t error = init_rgb_output();
    s_rgb_ready = error == ESP_OK;
    rig_state_set_light(s_rgb_ready, s_command.brightness, s_active_preset,
                        rig_light_effect_name(s_command.effect));
    rig_state_set_test(s_rgb_ready ? "OFF" : "RGB INIT ERROR");
    xTaskCreate(light_task, "light_fx", 3072, NULL, 4, NULL);
    ESP_LOGI(TAG, "WS2812B output: %s; IO17, boot OFF, 800 kbit/s, %d GRB pixels, reset 320us",
             esp_err_to_name(error), LIGHT_RGB_PIXELS);
}

bool rig_light_apply(const light_command_t *command)
{
    if (!command || command->brightness > 100 || command->speed > 100 ||
        command->effect > LIGHT_EFFECT_COLOR_CYCLE) return false;
    if (command->enabled && command->mode != LIGHT_RGB) {
        rig_state_set_test("A/B NOT WIRED");
        return false;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    // Effect animation frames are background traffic. Only a change to the requested light wakes the LCD.
    if (command->enabled != s_command.enabled || command->mode != s_command.mode ||
        command->red != s_command.red || command->green != s_command.green || command->blue != s_command.blue ||
        command->warm != s_command.warm || command->cool != s_command.cool || command->speed != s_command.speed)
        rig_state_note_activity();
    s_command = *command;
    s_refresh_pending = true;
    s_active_preset = UINT8_MAX;
    xSemaphoreGive(s_lock);
    rig_state_set_light(s_rgb_ready, command->brightness, UINT8_MAX,
                        rig_light_effect_name(command->effect));
    char label[24];
    snprintf(label, sizeof(label), "%s %u", command->enabled ? rig_light_effect_name(command->effect) : "OFF", command->brightness);
    rig_state_set_test(label);
    return true;
}

bool rig_light_apply_preset(uint8_t slot)
{
    if (slot >= LIGHT_PRESET_COUNT) return false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_presets[slot].command.enabled && s_presets[slot].command.mode != LIGHT_RGB) {
        xSemaphoreGive(s_lock);
        rig_state_set_test("A/B NOT WIRED");
        return false;
    }
    s_command = s_presets[slot].command;
    s_refresh_pending = true;
    s_active_preset = slot;
    light_command_t applied = s_command;
    xSemaphoreGive(s_lock);
    rig_state_set_light(s_rgb_ready, applied.brightness, slot,
                        rig_light_effect_name(applied.effect));
    rig_state_set_test(applied.enabled ? rig_light_effect_name(applied.effect) : "OFF");
    return true;
}

bool rig_light_save_preset(uint8_t slot, const char *name, const light_command_t *command)
{
    if (slot >= LIGHT_PRESET_COUNT || !name || !command || command->brightness > 100 ||
        command->speed > 100 || command->effect > LIGHT_EFFECT_COLOR_CYCLE) return false;
    stored_preset_t preset = {.magic = LIGHT_PRESET_MAGIC, .command = *command};
    strlcpy(preset.name, name, sizeof(preset.name));
    nvs_handle_t nvs;
    if (nvs_open(LIGHT_NVS_NAMESPACE, NVS_READWRITE, &nvs) != ESP_OK) return false;
    char key[4];
    snprintf(key, sizeof(key), "p%u", slot);
    esp_err_t error = nvs_set_blob(nvs, key, &preset, sizeof(preset));
    if (error == ESP_OK) error = nvs_commit(nvs);
    nvs_close(nvs);
    if (error != ESP_OK) return false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_presets[slot] = preset;
    rig_state_note_activity();
    xSemaphoreGive(s_lock);
    return true;
}

light_command_t rig_light_get_command(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    light_command_t copy = s_command;
    xSemaphoreGive(s_lock);
    return copy;
}

light_frame_t rig_light_get_frame(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    light_frame_t copy = s_frame;
    xSemaphoreGive(s_lock);
    return copy;
}

bool rig_light_is_ready(void) { return s_rgb_ready; }

light_output_status_t rig_light_get_output_status(void)
{
    light_output_status_t status = {.gpio = LIGHT_RGB_GPIO};
    gpio_io_config_t config = {0};
    if (gpio_get_io_config(LIGHT_RGB_GPIO, &config) == ESP_OK) {
        status.valid = true;
        status.pull_up = config.pu;
        status.pull_down = config.pd;
    }
    if (s_lock) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        status.tx_frames = s_tx_frames;
        status.last_tx = s_last_tx;
        xSemaphoreGive(s_lock);
    }
    return status;
}

bool rig_light_run_rgb_test(void)
{
    if (s_rgb_ready) {
        rig_state_set_test("OUTPUT BUSY");
        return false;
    }
    rig_state_set_test("STARTING");
    vTaskDelay(pdMS_TO_TICKS(300));
    esp_err_t error = init_rgb_output();
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "cannot start direct RGB test: %s", esp_err_to_name(error));
        char status[24];
        snprintf(status, sizeof(status), "INIT ERR %04X", (unsigned)error);
        rig_state_set_test(status);
        return false;
    }

    static const struct {
        const char *name;
        uint8_t red;
        uint8_t green;
        uint8_t blue;
    } steps[] = {
        {"RED", 32, 0, 0},
        {"GREEN", 0, 32, 0},
        {"BLUE", 0, 0, 32},
        {"WHITE", 16, 16, 16},
        {"OFF", 0, 0, 0},
    };

    for (size_t i = 0; i < sizeof(steps) / sizeof(steps[0]); i++) {
        char status[24];
        snprintf(status, sizeof(status), "WS2812B %s", steps[i].name);
        rig_state_set_test(status);
        ESP_LOGI(TAG, "RGB test: %s", status);
        error = send_rgb(steps[i].red, steps[i].green, steps[i].blue);
        if (error != ESP_OK) {
            ESP_LOGE(TAG, "RGB test transmission failed: %s", esp_err_to_name(error));
            send_rgb(0, 0, 0);
            rig_state_set_test("TEST FAILED");
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
    rig_state_set_test("SENT. BOOT RETRY");
    // Successful transmission does not establish that the lamp accepted it.
    // Keep the effect task disabled and permit another button-triggered test.
    ESP_LOGI(TAG, "test frames sent; lamp response requires visual confirmation");
    return true;
}

const char *rig_light_effect_name(light_effect_t effect)
{
    switch (effect) {
        case LIGHT_EFFECT_SOLID: return "solid";
        case LIGHT_EFFECT_BREATHE: return "breathe";
        case LIGHT_EFFECT_RAINBOW: return "rainbow";
        case LIGHT_EFFECT_COLOR_CYCLE: return "color_cycle";
        default: return "unknown";
    }
}

bool rig_light_effect_parse(const char *value, light_effect_t *effect)
{
    if (!value || !effect) return false;
    const struct { const char *name; light_effect_t value; } choices[] = {
        {"solid", LIGHT_EFFECT_SOLID}, {"breathe", LIGHT_EFFECT_BREATHE},
        {"rainbow", LIGHT_EFFECT_RAINBOW}, {"color_cycle", LIGHT_EFFECT_COLOR_CYCLE},
    };
    for (size_t i = 0; i < sizeof(choices) / sizeof(choices[0]); i++) {
        if (strcmp(value, choices[i].name) == 0) { *effect = choices[i].value; return true; }
    }
    return false;
}
