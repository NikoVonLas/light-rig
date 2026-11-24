#include "rig_light_probe.h"

#include "driver/rmt_rx.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include <stdio.h>

#define PROBE_GPIO GPIO_NUM_18
#define PROBE_RESOLUTION_HZ 20000000U
#define PROBE_SYMBOL_COUNT 1024
#define PROBE_LOG_SYMBOL_COUNT 256

static const char *TAG = "light_probe";
static rmt_channel_handle_t s_channel;
static rmt_symbol_word_t s_symbols[PROBE_SYMBOL_COUNT];
static QueueHandle_t s_queue;
static SemaphoreHandle_t s_lock;
static light_probe_result_t s_result;

static bool probe_done(rmt_channel_handle_t channel, const rmt_rx_done_event_data_t *event,
                       void *context)
{
    (void)channel;
    BaseType_t wake = pdFALSE;
    xQueueSendFromISR((QueueHandle_t)context, event, &wake);
    return wake == pdTRUE;
}

static uint32_t ticks_to_ns(uint16_t ticks)
{
    return (uint64_t)ticks * 1000000000ULL / PROBE_RESOLUTION_HZ;
}

static void log_symbols(const rmt_rx_done_event_data_t *event)
{
    size_t count = event->num_symbols;
    if (count > PROBE_LOG_SYMBOL_COUNT) count = PROBE_LOG_SYMBOL_COUNT;

    for (size_t base = 0; base < count; base += 4) {
        char line[240];
        size_t used = 0;
        for (size_t i = base; i < count && i < base + 4; i++) {
            const rmt_symbol_word_t *symbol = &event->received_symbols[i];
            int written = snprintf(line + used, sizeof(line) - used,
                                   "%s%03u=%u/%lu,%u/%lu",
                                   i == base ? "" : " ", (unsigned)i,
                                   (unsigned)symbol->level0,
                                   (unsigned long)ticks_to_ns(symbol->duration0),
                                   (unsigned)symbol->level1,
                                   (unsigned long)ticks_to_ns(symbol->duration1));
            if (written < 0 || (size_t)written >= sizeof(line) - used) break;
            used += (size_t)written;
        }
        ESP_LOGI(TAG, "RAW %s", line);
    }
    if (event->num_symbols > count) {
        ESP_LOGI(TAG, "RAW truncated: logged first %u of %u symbols",
                 (unsigned)count, (unsigned)event->num_symbols);
    }
}

static void probe_task(void *argument)
{
    (void)argument;
    rmt_rx_done_event_data_t event;
    while (true) {
        if (xQueueReceive(s_queue, &event, portMAX_DELAY) != pdPASS) continue;
        uint32_t minimum = UINT32_MAX, maximum = 0;
        size_t data_pulses = 0;
        for (size_t i = 0; i < event.num_symbols; i++) {
            uint16_t durations[] = {
                event.received_symbols[i].duration0,
                event.received_symbols[i].duration1,
            };
            for (size_t part = 0; part < 2; part++) {
                if (!durations[part]) continue;
                uint32_t ns = ticks_to_ns(durations[part]);
                if (ns < minimum) minimum = ns;
                if (ns > maximum) maximum = ns;
                if (ns >= 150 && ns <= 1600) data_pulses++;
            }
        }
        if (minimum == UINT32_MAX) minimum = 0;
        xSemaphoreTake(s_lock, portMAX_DELAY);
        s_result.armed = false;
        s_result.captured = event.num_symbols > 0;
        s_result.symbols = event.num_symbols;
        s_result.minimum_ns = minimum;
        s_result.maximum_ns = maximum;
        s_result.ws2812_like = event.num_symbols >= 12 && data_pulses >= event.num_symbols &&
                               minimum >= 150 && minimum <= 700 &&
                               maximum >= 600 && maximum <= 1800;
        light_probe_result_t result = s_result;
        xSemaphoreGive(s_lock);
        ESP_LOGI(TAG, "RGB capture: %u symbols, %lu..%lu ns, WS2812-like=%s",
                 (unsigned)result.symbols, (unsigned long)result.minimum_ns,
                 (unsigned long)result.maximum_ns, result.ws2812_like ? "yes" : "no");
        log_symbols(&event);
    }
}

void rig_light_probe_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    s_queue = xQueueCreate(1, sizeof(rmt_rx_done_event_data_t));
    rmt_rx_channel_config_t config = {
        .gpio_num = PROBE_GPIO,
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = PROBE_RESOLUTION_HZ,
        // Two hardware blocks enable ping-pong reception into the larger user buffer.
        .mem_block_symbols = 128,
    };
    ESP_ERROR_CHECK(rmt_new_rx_channel(&config, &s_channel));
    rmt_rx_event_callbacks_t callbacks = {.on_recv_done = probe_done};
    ESP_ERROR_CHECK(rmt_rx_register_event_callbacks(s_channel, &callbacks, s_queue));
    ESP_ERROR_CHECK(rmt_enable(s_channel));
    xTaskCreate(probe_task, "light_probe", 3072, NULL, 5, NULL);
    ESP_LOGI(TAG, "safe RGB capture input ready on GPIO18 (5 V-tolerant buffer required)");
}

bool rig_light_probe_arm(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (!s_channel || s_result.armed) {
        xSemaphoreGive(s_lock);
        return false;
    }
    s_result = (light_probe_result_t){.armed = true};
    xSemaphoreGive(s_lock);
    const rmt_receive_config_t config = {
        .signal_range_min_ns = 50,
        .signal_range_max_ns = 200000,
    };
    esp_err_t error = rmt_receive(s_channel, s_symbols, sizeof(s_symbols), &config);
    if (error != ESP_OK) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        s_result.armed = false;
        xSemaphoreGive(s_lock);
        ESP_LOGE(TAG, "failed to arm capture: %s", esp_err_to_name(error));
        return false;
    }
    return true;
}

bool rig_light_probe_release(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (!s_channel || s_result.armed) {
        xSemaphoreGive(s_lock);
        return false;
    }
    rmt_channel_handle_t channel = s_channel;
    s_channel = NULL;
    xSemaphoreGive(s_lock);

    esp_err_t error = rmt_disable(channel);
    if (error == ESP_OK) error = rmt_del_channel(channel);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "failed to release RGB capture channel: %s", esp_err_to_name(error));
        return false;
    }
    ESP_LOGI(TAG, "RGB capture released; GPIO18 can be switched to direct output");
    return true;
}

light_probe_result_t rig_light_probe_get(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    light_probe_result_t copy = s_result;
    xSemaphoreGive(s_lock);
    return copy;
}
