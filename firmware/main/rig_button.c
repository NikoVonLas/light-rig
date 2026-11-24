#include "rig_button.h"

#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "rig_light.h"
#include "rig_state.h"

#define BOOT_BUTTON_GPIO GPIO_NUM_0

static void button_task(void *argument)
{
    (void)argument;
    bool previous = true;
    TickType_t pressed_at = 0;
    unsigned selection = 0;
    static const char *names[] = {"OFF", "RED", "GREEN", "BLUE", "RGB WHITE", "SUNSET", "RAINBOW", "BREATHE"};
    while (true) {
        bool level = gpio_get_level(BOOT_BUTTON_GPIO);
        if (previous && !level) {
            pressed_at = xTaskGetTickCount();
            ESP_LOGI("rig_button", "BOOT pressed on GPIO0");
        } else if (!previous && level) {
            TickType_t held = xTaskGetTickCount() - pressed_at;
            ESP_LOGI("rig_button", "BOOT released after %lu ms", (unsigned long)(held * portTICK_PERIOD_MS));
            if (held >= pdMS_TO_TICKS(60)) {
                selection = held >= pdMS_TO_TICKS(1200) ? 0 : (selection + 1) % 8;
                light_command_t command = {.enabled=selection != 0, .mode=LIGHT_RGB,
                    .brightness=50, .speed=30, .effect=LIGHT_EFFECT_SOLID};
                switch (selection) {
                    case 1: command.red=255; break;
                    case 2: command.green=255; break;
                    case 3: command.blue=255; break;
                    case 4: command.red=command.green=command.blue=128; break;
                    case 5: command.red=255; command.green=90; command.blue=15; break;
                    case 6: command.effect=LIGHT_EFFECT_RAINBOW; break;
                    case 7: command.red=40; command.green=100; command.blue=255; command.effect=LIGHT_EFFECT_BREATHE; break;
                }
                if (rig_light_apply(&command)) rig_state_set_test(names[selection]);
            }
        }
        previous = level;
        vTaskDelay(pdMS_TO_TICKS(30));
    }
}

void rig_button_init(void)
{
    gpio_config_t config = {
        .pin_bit_mask = 1ULL << BOOT_BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&config));
    xTaskCreate(button_task, "rig_button", 4096, NULL, 5, NULL);
}
