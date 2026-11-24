#include "rig_display.h"
#include "rig_boot_mark.h"

#include <ctype.h>
#include <stdatomic.h>
#include "esp_timer.h"
#include <string.h>
#include <stdio.h>
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "rig_state.h"
#include "rig_light.h"

#define LCD_HOST SPI2_HOST
#define LCD_WIDTH 240
#define LCD_HEIGHT 135
#define PIN_MOSI 35
#define PIN_MISO 4
#define PIN_CLK 36
#define PIN_CS 34
#define PIN_DC 37
#define PIN_RST 38
#define PIN_BL 33
#define PIN_PERIPHERAL_POWER 14

static const char *TAG = "rig_display";
static esp_lcd_panel_handle_t s_panel;
static uint16_t *s_framebuffer;
static uint16_t *s_dma_strip;
static SemaphoreHandle_t s_transfer_done;
#define LCD_STRIP_ROWS 8
#define DISPLAY_IDLE_US (60LL * 1000000)
static atomic_bool s_awake;

bool rig_display_is_awake(void) { return atomic_load(&s_awake); }

static bool color_done(esp_lcd_panel_io_handle_t io, esp_lcd_panel_io_event_data_t *event, void *context)
{
    (void)io; (void)event; (void)context;
    BaseType_t wake = pdFALSE;
    xSemaphoreGiveFromISR(s_transfer_done, &wake);
    return wake == pdTRUE;
}

static void flush_frame(void)
{
    for (int y = 0; y < LCD_HEIGHT; y += LCD_STRIP_ROWS) {
        int rows = LCD_HEIGHT - y;
        if (rows > LCD_STRIP_ROWS) rows = LCD_STRIP_ROWS;
        memcpy(s_dma_strip, s_framebuffer + y * LCD_WIDTH, rows * LCD_WIDTH * sizeof(uint16_t));
        ESP_ERROR_CHECK(esp_lcd_panel_draw_bitmap(s_panel, 0, y, LCD_WIDTH, y + rows, s_dma_strip));
        xSemaphoreTake(s_transfer_done, portMAX_DELAY);
    }
}

// Five columns per glyph, least-significant bit at the top. Space, A-Z, 0-9,
// dash, dot, colon, slash and underscore are enough for the device UI.
static const char s_glyph_names[] = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:/_";
static const uint8_t s_glyphs[][5] = {
    {0,0,0,0,0}, {0x7e,0x11,0x11,0x11,0x7e}, {0x7f,0x49,0x49,0x49,0x36},
    {0x3e,0x41,0x41,0x41,0x22}, {0x7f,0x41,0x41,0x22,0x1c}, {0x7f,0x49,0x49,0x49,0x41},
    {0x7f,0x09,0x09,0x09,0x01}, {0x3e,0x41,0x49,0x49,0x7a}, {0x7f,0x08,0x08,0x08,0x7f},
    {0x00,0x41,0x7f,0x41,0x00}, {0x20,0x40,0x41,0x3f,0x01}, {0x7f,0x08,0x14,0x22,0x41},
    {0x7f,0x40,0x40,0x40,0x40}, {0x7f,0x02,0x0c,0x02,0x7f}, {0x7f,0x04,0x08,0x10,0x7f},
    {0x3e,0x41,0x41,0x41,0x3e}, {0x7f,0x09,0x09,0x09,0x06}, {0x3e,0x41,0x51,0x21,0x5e},
    {0x7f,0x09,0x19,0x29,0x46}, {0x46,0x49,0x49,0x49,0x31}, {0x01,0x01,0x7f,0x01,0x01},
    {0x3f,0x40,0x40,0x40,0x3f}, {0x1f,0x20,0x40,0x20,0x1f}, {0x3f,0x40,0x38,0x40,0x3f},
    {0x63,0x14,0x08,0x14,0x63}, {0x07,0x08,0x70,0x08,0x07}, {0x61,0x51,0x49,0x45,0x43},
    {0x3e,0x51,0x49,0x45,0x3e}, {0x00,0x42,0x7f,0x40,0x00}, {0x42,0x61,0x51,0x49,0x46},
    {0x21,0x41,0x45,0x4b,0x31}, {0x18,0x14,0x12,0x7f,0x10}, {0x27,0x45,0x45,0x45,0x39},
    {0x3c,0x4a,0x49,0x49,0x30}, {0x01,0x71,0x09,0x05,0x03}, {0x36,0x49,0x49,0x49,0x36},
    {0x06,0x49,0x49,0x29,0x1e}, {0x08,0x08,0x08,0x08,0x08}, {0,0x60,0x60,0,0},
    {0,0x36,0x36,0,0}, {0x20,0x10,0x08,0x04,0x02}, {0x40,0x40,0x40,0x40,0x40},
};

static uint16_t rgb565(uint8_t red, uint8_t green, uint8_t blue)
{
    uint16_t value = ((red & 0xf8) << 8) | ((green & 0xfc) << 3) | (blue >> 3);
    return (value >> 8) | (value << 8); // SPI panel expects big-endian RGB565 bytes.
}

static void fill(uint16_t color)
{
    for (size_t i = 0; i < LCD_WIDTH * LCD_HEIGHT; i++) s_framebuffer[i] = color;
}

static void rectangle(int x, int y, int width, int height, uint16_t color)
{
    if (x < 0 || y < 0 || x + width > LCD_WIDTH || y + height > LCD_HEIGHT) return;
    for (int row = y; row < y + height; row++) {
        for (int column = x; column < x + width; column++) {
            s_framebuffer[row * LCD_WIDTH + column] = color;
        }
    }
}

static const uint8_t *glyph_for(char character)
{
    character = (char)toupper((unsigned char)character);
    const char *found = strchr(s_glyph_names, character);
    return found ? s_glyphs[found - s_glyph_names] : s_glyphs[0];
}

static void draw_text(int x, int y, const char *text, int scale, uint16_t color)
{
    for (; text && *text; text++, x += 6 * scale) {
        const uint8_t *glyph = glyph_for(*text);
        for (int column = 0; column < 5; column++) {
            for (int row = 0; row < 7; row++) {
                if (glyph[column] & (1U << row)) {
                    rectangle(x + column * scale, y + row * scale, scale, scale, color);
                }
            }
        }
    }
}

static void display_task(void *argument)
{
    (void)argument;
    // Keep the boot mark visible while the other peripherals start.
    vTaskDelay(pdMS_TO_TICKS(900));
    uint32_t previous_revision = 0;
    int64_t last_change = esp_timer_get_time();
    while (true) {
        rig_snapshot_t state = rig_state_get();
        int64_t now = esp_timer_get_time();
        if (state.revision != previous_revision) {
            last_change = now;
            uint16_t accent = rgb565(53, 199, 89);
            if (state.mode == RIG_ON_CALL) accent = rgb565(255, 69, 58);
            if (state.mode == RIG_PREPARING) accent = rgb565(255, 159, 10);
            if (state.mode == RIG_MANUAL) accent = rgb565(10, 132, 255);
            if (state.mode == RIG_FAULT) accent = rgb565(255, 45, 85);

            fill(rgb565(10, 13, 18));
            rectangle(0, 0, 8, LCD_HEIGHT, accent);
            draw_text(16, 12, state.mode == RIG_ON_CALL ? "ON CALL" : rig_mode_name(state.mode), 3, rgb565(245, 247, 250));
            draw_text(16, 43, state.camera_status, 1, state.camera_connected ? accent : rgb565(255, 204, 0));
            draw_text(16, 61, state.camera_exposure_line, 1, rgb565(245, 247, 250));
            draw_text(16, 79, state.camera_focus_line, 1, rgb565(160, 170, 184));
            light_command_t light = rig_light_get_command();
            char line[38];
            bool has_address = strchr(state.ip_address, '.') != NULL;
            const char *network = state.wifi_connected ? "WIFI" : (has_address ? "AP" : "USB");
            snprintf(line, sizeof(line), "RGB %s %u / %s%s%s", light.enabled ? "ON" : "OFF",
                light.brightness, network, has_address ? " " : "", has_address ? state.ip_address : "");
            draw_text(16, 97, line, 1, rgb565(160, 170, 184));
            draw_text(16, 117, state.camera_command_status[0] ? state.camera_command_status : state.test_status, 1, accent);
            flush_frame();
            if (!rig_display_is_awake()) {
                ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(s_panel, true));
                ESP_ERROR_CHECK(gpio_set_level(PIN_BL, 1));
                atomic_store(&s_awake, true);
            }
            previous_revision = state.revision;
        }
        if (state.mode != RIG_ON_CALL && rig_display_is_awake() && now - last_change >= DISPLAY_IDLE_US) {
            ESP_ERROR_CHECK(gpio_set_level(PIN_BL, 0));
            ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(s_panel, false));
            atomic_store(&s_awake, false);
        }
        vTaskDelay(pdMS_TO_TICKS(150));
    }
}

void rig_display_init(void)
{
    // The T-Display-S2 reference example enables this peripheral supply
    // before initializing the TFT/SD. Backlight GPIO33 alone is insufficient.
    gpio_config_t power = {
        .pin_bit_mask = 1ULL << PIN_PERIPHERAL_POWER,
        .mode = GPIO_MODE_OUTPUT,
    };
    ESP_ERROR_CHECK(gpio_config(&power));
    ESP_ERROR_CHECK(gpio_set_level(PIN_PERIPHERAL_POWER, 1));
    vTaskDelay(pdMS_TO_TICKS(100));
    ESP_LOGI(TAG, "LCD V3: peripheral power GPIO14 enabled");
    gpio_config_t backlight = {
        .pin_bit_mask = 1ULL << PIN_BL,
        .mode = GPIO_MODE_OUTPUT,
    };
    ESP_ERROR_CHECK(gpio_config(&backlight));
    gpio_set_level(PIN_BL, 0);

    spi_bus_config_t bus = {
        .sclk_io_num = PIN_CLK,
        .mosi_io_num = PIN_MOSI,
        .miso_io_num = PIN_MISO,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = LCD_WIDTH * LCD_STRIP_ROWS * sizeof(uint16_t),
    };
    ESP_ERROR_CHECK(spi_bus_initialize(LCD_HOST, &bus, SPI_DMA_CH_AUTO));

    esp_lcd_panel_io_handle_t io = NULL;
    esp_lcd_panel_io_spi_config_t io_config = {
        .dc_gpio_num = PIN_DC,
        .cs_gpio_num = PIN_CS,
        .pclk_hz = 40 * 1000 * 1000,
        .lcd_cmd_bits = 8,
        .lcd_param_bits = 8,
        .spi_mode = 0,
        .trans_queue_depth = 1, // flush_frame waits for each strip.
    };
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_HOST,
                                              &io_config, &io));
    esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = PIN_RST,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
    };
    ESP_ERROR_CHECK(esp_lcd_new_panel_st7789(io, &panel_config, &s_panel));
    ESP_ERROR_CHECK(esp_lcd_panel_reset(s_panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(s_panel));
    ESP_ERROR_CHECK(esp_lcd_panel_invert_color(s_panel, true));
    ESP_ERROR_CHECK(esp_lcd_panel_swap_xy(s_panel, true));
    ESP_ERROR_CHECK(esp_lcd_panel_mirror(s_panel, true, false));
    ESP_ERROR_CHECK(esp_lcd_panel_set_gap(s_panel, 40, 53));
    ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(s_panel, true));

    // Full frame lives in PSRAM; only a small DMA strip needs scarce internal
    // RAM. This leaves room for concurrent Wi-Fi, HTTP, UART and USB-host tasks.
    s_framebuffer = heap_caps_malloc(LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t),
                                     MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    s_dma_strip = heap_caps_malloc(LCD_WIDTH * LCD_STRIP_ROWS * sizeof(uint16_t),
                                  MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    s_transfer_done = xSemaphoreCreateBinary();
    if (!s_framebuffer || !s_dma_strip || !s_transfer_done) {
        ESP_LOGE(TAG, "failed to allocate display framebuffer");
        rig_state_set_fault("display memory");
        return;
    }
    const esp_lcd_panel_io_callbacks_t callbacks = {.on_color_trans_done = color_done};
    ESP_ERROR_CHECK(esp_lcd_panel_io_register_event_callbacks(io, &callbacks, NULL));
    const uint16_t background = rgb565(10, 13, 18);
    const uint16_t icon[] = {background, rgb565(40, 77, 38), rgb565(70, 140, 59), rgb565(99, 204, 79)};
    const uint16_t title[] = {background, rgb565(88, 91, 95), rgb565(167, 169, 173), rgb565(245, 247, 250)};
    fill(background);
    for (int y = 0; y < BOOT_MARK_HEIGHT; y++) {
        const uint16_t *palette = y < BOOT_ICON_ROWS ? icon : title;
        uint16_t *row = s_framebuffer + ((LCD_HEIGHT - BOOT_MARK_HEIGHT) / 2 + y) * LCD_WIDTH
                                      + (LCD_WIDTH - BOOT_MARK_WIDTH) / 2;
        for (int x = 0; x < BOOT_MARK_WIDTH; x++) {
            unsigned shift = 6 - 2 * (x % 4);
            row[x] = palette[(boot_mark[y][x / 4] >> shift) & 3];
        }
    }
    flush_frame();
    ESP_ERROR_CHECK(gpio_set_level(PIN_BL, 1));
    atomic_store(&s_awake, true);
    if (xTaskCreate(display_task, "rig_display", 4096, NULL, 4, NULL) != pdPASS) {
        ESP_LOGE(TAG, "display task creation failed");
        rig_state_set_fault("display task");
    }
}
