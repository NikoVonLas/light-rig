#include "esp_app_desc.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "nvs_flash.h"
#include "rig_button.h"
#include "rig_camera.h"
#include "rig_display.h"
#include "rig_light.h"
#include "rig_light_probe.h"
#include "rig_network.h"
#include "rig_presence.h"
#include "rig_homeassistant.h"
#include "rig_state.h"

static const char *TAG = "canon_rig";

void app_main(void)
{
    esp_err_t error = nvs_flash_init();
    if (error == ESP_ERR_NVS_NO_FREE_PAGES || error == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        error = nvs_flash_init();
    }
    ESP_ERROR_CHECK(error);

    rig_network_prepare_ap_password();
    rig_state_init();
    rig_light_probe_init();
    rig_light_init();
    // The display reads light state: initialize the driver's mutex first.
    rig_display_init();
    rig_button_init();
    rig_camera_init();
    rig_presence_init();
    rig_homeassistant_init();
    rig_network_init();

    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t state;
    if (esp_ota_get_state_partition(running, &state) == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY) {
        ESP_LOGI(TAG, "new OTA image reached healthy application state; accepting it");
        ESP_ERROR_CHECK(esp_ota_mark_app_valid_cancel_rollback());
    }
    ESP_LOGI(TAG, "Canon Rig firmware %s started", esp_app_get_description()->version);
}
