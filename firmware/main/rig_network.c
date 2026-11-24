#include "esp_attr.h"
#include "rig_network.h"
#include "rig_ota.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cJSON.h"
#include "driver/uart.h"
#include "freertos/semphr.h"
#include "esp_app_desc.h"
#include "esp_event.h"
#include "esp_http_server.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"
#include "mdns.h"
#include "nvs.h"
#include "rig_light.h"
#include "rig_light_probe.h"
#include "rig_state.h"
#include "rig_display.h"
#include "presence_model.h"
#include "esp_timer.h"
#include "rig_camera.h"
#include "rig_presence.h"
#include "rig_homeassistant.h"
#include "wifi_retry.h"
#include "usb/usb_host.h"
#include <math.h>
#include "esp_random.h"
#include "bootloader_random.h"

#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAILED_BIT BIT1
#define WIFI_NAMESPACE "wifi"

static const char *TAG = "rig_network";
static EventGroupHandle_t s_wifi_events;
static bool s_wifi_initialized;
static bool s_scan_running;
static char s_scan_status[16] = "idle";
static char s_station_ssid[33];
static wifi_ap_record_t s_scan_results[16];
static uint16_t s_scan_count;
static void wifi_stack_init(void);
static httpd_handle_t s_http_server;
static SemaphoreHandle_t s_command_lock;
static SemaphoreHandle_t s_wifi_operation_lock;
static SemaphoreHandle_t s_wifi_scan_lock;
static char s_network_mode[8] = "usb";
static bool s_restarting;
// CH340 exposes UART traffic, not a physical USB attach pin. Only the serial task updates this lease.
static int64_t s_last_serial_request_us;
static bool load_wifi(char *ssid, size_t ssid_size, char *password, size_t password_size);

static void exposure_property_json(cJSON *parent, const char *name, const eos_property_t *property)
{
    cJSON *object = cJSON_AddObjectToObject(parent, name);
    if (property->known) cJSON_AddNumberToObject(object, "raw", property->value);
    else cJSON_AddNullToObject(object, "raw");
    cJSON_AddBoolToObject(object, "optionsKnown", property->options_known);
    cJSON *options = cJSON_AddArrayToObject(object, "options");
    for (uint32_t i = 0; i < property->option_count; i++)
        cJSON_AddItemToArray(options, cJSON_CreateNumber(property->options[i]));
}

static char *snapshot_json(const char *id, const char *type)
{
    rig_snapshot_t state = rig_state_get();
    cJSON *root = cJSON_CreateObject();
    cJSON_AddNumberToObject(root, "v", 1);
    cJSON_AddStringToObject(root, "id", id ? id : "state");
    cJSON_AddStringToObject(root, "type", type ? type : "rig.state");
    cJSON *payload = cJSON_AddObjectToObject(root, "payload");
    cJSON_AddBoolToObject(payload, "displayAwake", rig_display_is_awake());
    rig_presence_json(payload);
    rig_homeassistant_json(payload);
    cJSON_AddStringToObject(payload, "mode", rig_mode_name(state.mode));
    cJSON_AddBoolToObject(payload, "wifiConnected", state.wifi_connected);
    cJSON_AddStringToObject(payload, "ipAddress", state.ip_address);
    cJSON_AddBoolToObject(payload, "cameraConnected", state.camera_connected);
    cJSON_AddBoolToObject(payload, "cameraUSBConnected", state.camera_usb_connected);
    cJSON_AddBoolToObject(payload, "cameraUSBLineAttached", state.camera_usb_line_attached);
    cJSON_AddNumberToObject(payload, "cameraGeneration", state.camera_generation);
    cJSON_AddBoolToObject(payload, "cameraPTPInterface", state.camera_ptp_interface);
    cJSON_AddNumberToObject(payload, "cameraVendorID", state.camera_vendor_id);
    cJSON_AddNumberToObject(payload, "cameraProductID", state.camera_product_id);
    cJSON_AddStringToObject(payload, "cameraStatus", state.camera_status);
    cJSON_AddStringToObject(payload, "cameraModel", state.camera_info.model);
    cJSON_AddStringToObject(payload, "cameraFirmware", state.camera_info.version);
    cJSON_AddNumberToObject(payload, "cameraOperationCount", state.camera_info.operation_count);
    cJSON_AddNumberToObject(payload, "cameraPropertyCount", state.camera_info.property_count);
    cJSON *capabilities = cJSON_AddObjectToObject(payload, "cameraCapabilities");
    cJSON_AddBoolToObject(capabilities, "set", state.camera_connected && state.camera_can_set);
    cJSON_AddBoolToObject(capabilities, "autofocus", state.camera_connected && state.camera_can_af);
    cJSON_AddBoolToObject(capabilities, "cancelAF", state.camera_connected && state.camera_can_cancel_af);
    cJSON_AddBoolToObject(capabilities, "focusStep", state.camera_connected && state.camera_can_focus_step);
    bool touch_af = state.camera_connected && (state.camera_extra_operations & 3) == 3 && state.camera_can_af && state.camera_can_cancel_af;
    cJSON_AddBoolToObject(capabilities, "prepareFocus", touch_af);
    cJSON_AddBoolToObject(capabilities, "focusPoint", touch_af && state.camera_af_width && state.camera_af_height);
    cJSON *command = cJSON_AddObjectToObject(payload, "cameraCommand");
    cJSON_AddStringToObject(command, "id", state.camera_command_id);
    cJSON_AddStringToObject(command, "status", state.camera_command_status);
    cJSON_AddStringToObject(command, "message", state.camera_command_message);
    eos_exposure_t exposure;
    rig_state_get_exposure(&exposure);
    cJSON *exposure_json = cJSON_AddObjectToObject(payload, "cameraExposure");
    exposure_property_json(exposure_json, "aperture", &exposure.aperture);
    exposure_property_json(exposure_json, "shutter", &exposure.shutter);
    exposure_property_json(exposure_json, "iso", &exposure.iso);
    exposure_property_json(exposure_json, "focusMode", &exposure.focus_mode);
    exposure_property_json(exposure_json, "afMethod", &exposure.af_method);
    exposure_property_json(exposure_json, "movieServo", &exposure.movie_servo);
    exposure_property_json(exposure_json, "autoPowerOff", &exposure.auto_power_off);
    cJSON *diagnostics = cJSON_AddObjectToObject(payload, "cameraDiagnostics");
    cJSON_AddNumberToObject(diagnostics, "operationFlags", state.camera_extra_operations);
    cJSON_AddBoolToObject(diagnostics, "pollingPaused", state.camera_polling_paused);
    if (exposure.power_off_known) cJSON_AddNumberToObject(diagnostics, "autoPowerOff", exposure.power_off);
    if (exposure.evf_output_known) cJSON_AddNumberToObject(diagnostics, "evfOutput", exposure.evf_output);
    if (exposure.evf_mode_known) cJSON_AddNumberToObject(diagnostics, "evfMode", exposure.evf_mode);
    cJSON_AddNumberToObject(diagnostics, "focusWidth", exposure.focus_width);
    cJSON_AddNumberToObject(diagnostics, "focusHeight", exposure.focus_height);
    cJSON_AddNumberToObject(diagnostics, "focusImageWidth", exposure.focus_image_width);
    cJSON_AddNumberToObject(diagnostics, "focusImageHeight", exposure.focus_image_height);
    cJSON_AddNumberToObject(diagnostics, "afWidth", state.camera_af_width);
    cJSON_AddNumberToObject(diagnostics, "afHeight", state.camera_af_height);
    cJSON_AddNumberToObject(diagnostics, "jpegWidth", state.camera_jpeg_width);
    cJSON_AddNumberToObject(diagnostics, "jpegHeight", state.camera_jpeg_height);
    cJSON_AddBoolToObject(payload, "lightReady", state.light_ready);
    cJSON_AddBoolToObject(payload, "lightEnabled", rig_light_get_command().enabled);
    cJSON_AddNumberToObject(payload, "lightBrightness", state.light_brightness);
    cJSON_AddNumberToObject(payload, "lightPreset", state.light_preset);
    cJSON_AddStringToObject(payload, "lightEffect", state.light_effect);
    light_command_t preset = rig_light_get_call_preset();
    if (preset.mode == LIGHT_RGB) {
        cJSON *call_light = cJSON_AddObjectToObject(payload, "callLight");
        cJSON_AddNumberToObject(call_light, "red", preset.red);
        cJSON_AddNumberToObject(call_light, "green", preset.green);
        cJSON_AddNumberToObject(call_light, "blue", preset.blue);
        cJSON_AddNumberToObject(call_light, "brightness", preset.brightness);
        cJSON_AddNumberToObject(call_light, "speed", preset.speed);
        cJSON_AddStringToObject(call_light, "effect", rig_light_effect_name(preset.effect));
    }
    light_output_status_t output = rig_light_get_output_status();
    cJSON *output_json = cJSON_AddObjectToObject(payload, "lightOutput");
    cJSON_AddNumberToObject(output_json, "gpio", output.gpio);
    cJSON_AddBoolToObject(output_json, "valid", output.valid);
    cJSON_AddStringToObject(output_json, "profile", "WS2812B");
    cJSON_AddStringToObject(output_json, "transport", "spi-dma");
    cJSON_AddNumberToObject(output_json, "txFrames", output.tx_frames);
    cJSON_AddNumberToObject(output_json, "lastRed", output.last_tx.red);
    cJSON_AddNumberToObject(output_json, "lastGreen", output.last_tx.green);
    cJSON_AddNumberToObject(output_json, "lastBlue", output.last_tx.blue);
    if (output.valid) {
        cJSON_AddBoolToObject(output_json, "pullUp", output.pull_up);
        cJSON_AddBoolToObject(output_json, "pullDown", output.pull_down);
    }
    light_probe_result_t probe = rig_light_probe_get();
    cJSON *probe_json = cJSON_AddObjectToObject(payload, "lightProbe");
    cJSON_AddBoolToObject(probe_json, "armed", probe.armed);
    cJSON_AddBoolToObject(probe_json, "captured", probe.captured);
    cJSON_AddBoolToObject(probe_json, "ws2812Like", probe.ws2812_like);
    cJSON_AddNumberToObject(probe_json, "symbols", probe.symbols);
    cJSON_AddNumberToObject(probe_json, "minimumNs", probe.minimum_ns);
    cJSON_AddNumberToObject(probe_json, "maximumNs", probe.maximum_ns);
    cJSON_AddNumberToObject(payload, "revision", state.revision);
    cJSON_AddStringToObject(payload, "firmwareTarget", "Light-Rig-esp32s2");
    cJSON_AddNumberToObject(payload, "otaProtocol", 1);
    cJSON_AddNumberToObject(payload, "otaProgress", rig_ota_progress());
    cJSON_AddStringToObject(payload, "firmware", esp_app_get_description()->version);
    cJSON_AddStringToObject(payload, "networkMode", s_network_mode);
    cJSON_AddStringToObject(payload, "networkSSID", s_station_ssid);
    xSemaphoreTake(s_wifi_scan_lock, portMAX_DELAY);
    cJSON *scan = cJSON_AddObjectToObject(payload, "wifiScan");
    cJSON_AddStringToObject(scan, "status", s_scan_status);
    cJSON *networks = cJSON_AddArrayToObject(scan, "networks");
    for (uint16_t i = 0; i < s_scan_count; ++i) {
        cJSON *entry = cJSON_CreateObject();
        cJSON_AddStringToObject(entry, "ssid", (const char *)s_scan_results[i].ssid);
        cJSON_AddNumberToObject(entry, "rssi", s_scan_results[i].rssi);
        cJSON_AddItemToArray(networks, entry);
    }
    xSemaphoreGive(s_wifi_scan_lock);
    char *encoded = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    return encoded;
}

static esp_err_t send_json(httpd_req_t *request, const char *json)
{
    httpd_resp_set_type(request, "application/json");
    httpd_resp_set_hdr(request, "Cache-Control", "no-store");
    return httpd_resp_sendstr(request, json);
}

static esp_err_t health_handler(httpd_req_t *request)
{
    char *json = snapshot_json("health", "rig.state");
    esp_err_t result = send_json(request, json);
    free(json);
    return result;
}

static esp_err_t camera_link_handler(httpd_req_t *request)
{
    rig_snapshot_t state = rig_state_get();
    char json[224];
    usb_host_lib_info_t host;
    int objects = usb_host_lib_info(&host) == ESP_OK ? host.num_devices : -1;
    snprintf(json, sizeof(json),
             "{\"line\":%u,\"usb\":%u,\"ptp\":%u,\"objects\":%d,\"generation\":%lu,\"portRestarts\":%lu,\"largestDMA\":%u,\"status\":\"%.23s\"}",
             (unsigned)state.camera_usb_line_attached, (unsigned)state.camera_usb_connected,
             (unsigned)state.camera_connected, objects, (unsigned long)state.camera_generation,
             (unsigned long)state.camera_port_restarts,
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL), state.camera_status);
    return send_json(request, json);
}

static esp_err_t read_body(httpd_req_t *request, char **body)
{
    if (request->content_len <= 0 || request->content_len > 2048) return ESP_ERR_INVALID_SIZE;
    *body = calloc(1, request->content_len + 1);
    if (!*body) return ESP_ERR_NO_MEM;
    int received = 0;
    while (received < request->content_len) {
        int count = httpd_req_recv(request, *body + received, request->content_len - received);
        if (count <= 0) {
            free(*body);
            *body = NULL;
            return ESP_FAIL;
        }
        received += count;
    }
    return ESP_OK;
}

static esp_err_t wifi_config_handler(httpd_req_t *request)
{
    char *body = NULL;
    if (read_body(request, &body) != ESP_OK) {
        return httpd_resp_send_err(request, HTTPD_400_BAD_REQUEST, "invalid body");
    }
    cJSON *json = cJSON_Parse(body);
    free(body);
    cJSON *ssid = json ? cJSON_GetObjectItemCaseSensitive(json, "ssid") : NULL;
    cJSON *password = json ? cJSON_GetObjectItemCaseSensitive(json, "password") : NULL;
    if (!cJSON_IsString(ssid) || !cJSON_IsString(password) || strlen(ssid->valuestring) > 32 ||
        strlen(password->valuestring) > 63) {
        cJSON_Delete(json);
        return httpd_resp_send_err(request, HTTPD_400_BAD_REQUEST, "invalid credentials");
    }

    nvs_handle_t nvs;
    esp_err_t error = nvs_open(WIFI_NAMESPACE, NVS_READWRITE, &nvs);
    bool opened = error == ESP_OK;
    if (error == ESP_OK) error = nvs_set_str(nvs, "ssid", ssid->valuestring);
    if (error == ESP_OK) error = nvs_set_str(nvs, "password", password->valuestring);
    if (error == ESP_OK) error = nvs_set_str(nvs, "mode", "router");
    if (error == ESP_OK) error = nvs_commit(nvs);
    if (opened) nvs_close(nvs);
    cJSON_Delete(json);
    if (error != ESP_OK) return httpd_resp_send_err(request, HTTPD_500_INTERNAL_SERVER_ERROR, "NVS error");

    send_json(request, "{\"ok\":true,\"rebooting\":true}");
    vTaskDelay(pdMS_TO_TICKS(300));
    esp_restart();
    return ESP_OK;
}

static uint8_t json_u8(cJSON *payload, const char *key, uint8_t fallback, uint8_t maximum)
{
    cJSON *value = cJSON_GetObjectItemCaseSensitive(payload, key);
    if (!cJSON_IsNumber(value)) return fallback;
    if (value->valueint < 0) return 0;
    return value->valueint > maximum ? maximum : value->valueint;
}

static light_command_t parse_light_command(cJSON *payload)
{
    light_command_t command = rig_light_get_command();
    cJSON *enabled = cJSON_GetObjectItemCaseSensitive(payload, "enabled");
    cJSON *mode = cJSON_GetObjectItemCaseSensitive(payload, "mode");
    cJSON *effect = cJSON_GetObjectItemCaseSensitive(payload, "effect");
    if (cJSON_IsBool(enabled)) command.enabled = cJSON_IsTrue(enabled);
    command.brightness = json_u8(payload, "brightness", command.brightness, 100);
    command.red = json_u8(payload, "red", command.red, 255);
    command.green = json_u8(payload, "green", command.green, 255);
    command.blue = json_u8(payload, "blue", command.blue, 255);
    command.warm = json_u8(payload, "warm", command.warm, 100);
    command.cool = json_u8(payload, "cool", command.cool, 100);
    command.speed = json_u8(payload, "speed", command.speed, 100);
    if (cJSON_IsString(mode)) {
        if (strcmp(mode->valuestring, "rgb") == 0) command.mode = LIGHT_RGB;
        else if (strcmp(mode->valuestring, "warm") == 0) command.mode = LIGHT_WHITE_WARM;
        else if (strcmp(mode->valuestring, "cool") == 0) command.mode = LIGHT_WHITE_COOL;
        else if (strcmp(mode->valuestring, "neutral") == 0) command.mode = LIGHT_WHITE_NEUTRAL;
    }
    if (cJSON_IsString(effect)) rig_light_effect_parse(effect->valuestring, &command.effect);
    return command;
}

static const char *apply_command(cJSON *root)
{
    cJSON *type = cJSON_GetObjectItemCaseSensitive(root, "type");
    cJSON *payload = cJSON_GetObjectItemCaseSensitive(root, "payload");
    if (!cJSON_IsString(type) || !cJSON_IsObject(payload)) return "invalid command";

    if (strcmp(type->valuestring, "rig.setState") == 0) {
        cJSON *mode_value = cJSON_GetObjectItemCaseSensitive(payload, "mode");
        rig_mode_t mode;
        if (cJSON_IsString(mode_value) && rig_mode_parse(mode_value->valuestring, &mode)) {
            rig_state_set_mode(mode);
        }
    } else if (strcmp(type->valuestring, "light.set") == 0) {
        light_command_t command = parse_light_command(payload);
        rig_light_apply(&command);
    } else if (strcmp(type->valuestring, "light.applyPreset") == 0) {
        cJSON *slot = cJSON_GetObjectItemCaseSensitive(payload, "slot");
        if (cJSON_IsNumber(slot)) rig_light_apply_preset(slot->valueint);
    } else if (strcmp(type->valuestring, "preset.save") == 0) {
        cJSON *slot = cJSON_GetObjectItemCaseSensitive(payload, "slot");
        cJSON *name = cJSON_GetObjectItemCaseSensitive(payload, "name");
        if (!cJSON_IsNumber(slot) || slot->valuedouble != slot->valueint ||
            slot->valueint < 0 || slot->valueint > UINT8_MAX || !cJSON_IsString(name)) return "invalid preset";
        light_command_t command = parse_light_command(payload);
        if (!rig_light_save_preset(slot->valueint, name->valuestring, &command)) return "preset save failed";
    } else if (strcmp(type->valuestring, "light.captureStart") == 0) {
        rig_light_probe_arm();
    }
    return NULL;
}

static void scan_task(void *argument)
{
    (void)argument;
    xSemaphoreTake(s_wifi_operation_lock, portMAX_DELAY);
    wifi_stack_init();
    bool temporary = !strcmp(s_network_mode, "usb");
    esp_err_t error = ESP_OK;
    if (temporary) {
        error = esp_wifi_set_mode(WIFI_MODE_STA);
        if (error == ESP_OK) error = esp_wifi_start();
    }
    wifi_ap_record_t *records = calloc(32, sizeof(*records));
    if (!records) error = ESP_ERR_NO_MEM;
    uint16_t count = 32;
    wifi_scan_config_t scan = {0};
    if (!temporary && !rig_state_get().wifi_connected) esp_wifi_disconnect();
    if (error == ESP_OK) error = esp_wifi_scan_start(&scan, true);
    if (error == ESP_OK) error = esp_wifi_scan_get_ap_records(&count, records);
    else esp_wifi_clear_ap_list();
    if (temporary) esp_wifi_stop();
    xSemaphoreGive(s_wifi_operation_lock);
    xSemaphoreTake(s_command_lock, portMAX_DELAY);
    xSemaphoreTake(s_wifi_scan_lock, portMAX_DELAY);
    s_scan_count = 0;
    if (error == ESP_OK) {
        for (uint16_t i = 0; i < count && s_scan_count < 16; ++i) {
            wifi_auth_mode_t auth = records[i].authmode;
            if (!records[i].ssid[0] || (auth != WIFI_AUTH_WPA2_PSK &&
                auth != WIFI_AUTH_WPA_WPA2_PSK && auth != WIFI_AUTH_WPA2_WPA3_PSK &&
                auth != WIFI_AUTH_WPA3_PSK)) continue;
            bool duplicate = false;
            for (uint16_t j = 0; j < s_scan_count; ++j)
                if (!strcmp((char *)records[i].ssid, (char *)s_scan_results[j].ssid)) duplicate = true;
            if (!duplicate) s_scan_results[s_scan_count++] = records[i];
        }
    }
    free(records);
    strlcpy(s_scan_status, error == ESP_OK ? "ready" : "failed", sizeof(s_scan_status));
    rig_state_note_activity();
    s_scan_running = false;
    xSemaphoreGive(s_wifi_scan_lock);
    xSemaphoreGive(s_command_lock);
    vTaskDelete(NULL);
}

static const char *start_scan(bool usb)
{
    if (!usb) return "Wi-Fi scan requires USB";
    if (s_restarting) return "restart pending";
    if (s_scan_running) return NULL;
    s_scan_running = true;
    xSemaphoreTake(s_wifi_scan_lock, portMAX_DELAY);
    strlcpy(s_scan_status, "scanning", sizeof(s_scan_status));
    rig_state_note_activity();
    xSemaphoreGive(s_wifi_scan_lock);
    if (xTaskCreate(scan_task, "wifi_scan", 6144, NULL, 2, NULL) != pdPASS) {
        s_scan_running = false;
        xSemaphoreTake(s_wifi_scan_lock, portMAX_DELAY);
        strlcpy(s_scan_status, "failed", sizeof(s_scan_status));
        xSemaphoreGive(s_wifi_scan_lock);
        return "Wi-Fi scan unavailable";
    }
    return NULL;
}

static void restart_task(void *argument)
{
    (void)argument;
    vTaskDelay(pdMS_TO_TICKS(1000));
    esp_restart();
}

static esp_err_t read_ap_password(char password[64])
{
    nvs_handle_t nvs;
    esp_err_t error = nvs_open(WIFI_NAMESPACE, NVS_READONLY, &nvs);
    if (error == ESP_OK) {
        size_t size = 64;
        error = nvs_get_str(nvs, "ap_pass", password, &size);
        nvs_close(nvs);
    }
    return error;
}

// Before starting Wi-Fi or any peripheral sharing the hardware entropy source.
void rig_network_prepare_ap_password(void)
{
    char password[64] = {0};
    if (read_ap_password(password) != ESP_ERR_NVS_NOT_FOUND) return;
    uint8_t random[16];
    bootloader_random_enable();
    esp_fill_random(random, sizeof(random));
    bootloader_random_disable();
    for (size_t i = 0; i < sizeof(random); ++i)
        snprintf(password + i*2, 3, "%02x", random[i]);
    nvs_handle_t nvs;
    esp_err_t error = nvs_open(WIFI_NAMESPACE, NVS_READWRITE, &nvs);
    if (error == ESP_OK) {
        error = nvs_set_str(nvs, "ap_pass", password);
        if (error == ESP_OK) error = nvs_commit(nvs);
        nvs_close(nvs);
    }
    if (error != ESP_OK) ESP_LOGE(TAG, "Cannot provision access point");
}

static const char *configure_network(cJSON *payload, bool usb)
{
    cJSON *mode = cJSON_GetObjectItemCaseSensitive(payload, "mode");
    cJSON *ssid = cJSON_GetObjectItemCaseSensitive(payload, "ssid");
    cJSON *password = cJSON_GetObjectItemCaseSensitive(payload, "password");
    if (!cJSON_IsString(mode) || (strcmp(mode->valuestring, "usb") &&
        strcmp(mode->valuestring, "ap") && strcmp(mode->valuestring, "router"))) return "invalid network mode";
    cJSON *ap_password = cJSON_GetObjectItemCaseSensitive(payload, "apPassword");
    if (ap_password && (!usb || strcmp(mode->valuestring, "ap") || !cJSON_IsString(ap_password) ||
        strlen(ap_password->valuestring) < 8 || strlen(ap_password->valuestring) > 63))
        return "AP password requires USB and 8-63 bytes";
    bool credentials = ssid || password;
    if (credentials && (!cJSON_IsString(ssid) || !cJSON_IsString(password) ||
        strlen(ssid->valuestring) == 0 || strlen(ssid->valuestring) > 32 ||
        strlen(password->valuestring) < 8 || strlen(password->valuestring) > 63)) return "invalid Wi-Fi credentials";
    if (!strcmp(mode->valuestring, "router") && !credentials) {
        char saved_ssid[33] = {0}, saved_password[64] = {0};
        bool saved = load_wifi(saved_ssid, sizeof(saved_ssid), saved_password, sizeof(saved_password));
        memset(saved_password, 0, sizeof(saved_password));
        if (!saved) return "router credentials required";
    }
    if (s_restarting) return "restart pending";
    nvs_handle_t nvs;
    esp_err_t error = nvs_open(WIFI_NAMESPACE, NVS_READWRITE, &nvs);
    if (error != ESP_OK) return "NVS open failed";
    if (credentials) {
        error = nvs_set_str(nvs, "ssid", ssid->valuestring);
        if (error == ESP_OK) error = nvs_set_str(nvs, "password", password->valuestring);
    }
    if (error == ESP_OK && ap_password) error = nvs_set_str(nvs, "ap_pass", ap_password->valuestring);
    if (error == ESP_OK) error = nvs_set_str(nvs, "mode", mode->valuestring);
    if (error == ESP_OK) error = nvs_commit(nvs);
    nvs_close(nvs);
    if (error != ESP_OK) return "NVS write failed";
    s_restarting = true;
    if (xTaskCreate(restart_task, "network_restart", 2048, NULL, 3, NULL) != pdPASS) {
        s_restarting = false;
        return "saved; manual restart required";
    }
    return NULL;
}

// Both transports use exactly the same command handler and response format.
static const char *camera_command(const char *type, const char *id, cJSON *payload)
{
    if (!strcmp(type, "camera.pausePolling")) return rig_camera_submit(id, CAMERA_PAUSE_POLLING, 0, 0);
    if (!strcmp(type, "camera.wake")) return rig_camera_submit(id, CAMERA_WAKE, 0, 0);
    if (!strcmp(type, "camera.testEvfOff")) return rig_camera_submit(id, CAMERA_TEST_EVF_OFF, 0, 0);
    if (!strcmp(type, "camera.recoverVideo")) return rig_camera_submit(id, CAMERA_RECOVER_VIDEO, 0, 0);
    if (!strcmp(type, "camera.holdEvfOff")) return rig_camera_submit(id, CAMERA_HOLD_EVF_OFF, 0, 0);
    if (!strcmp(type, "camera.testRemoteOff")) return rig_camera_submit(id, CAMERA_TEST_REMOTE_OFF, 0, 0);
    if (!strcmp(type, "camera.testRemoteOn")) return rig_camera_submit(id, CAMERA_TEST_REMOTE_ON, 0, 0);
    if (!strcmp(type, "camera.testTerminateLV")) return rig_camera_submit(id, CAMERA_TEST_TERMINATE_LV, 0, 0);
    if (!strcmp(type, "camera.testEvfModeOff")) return rig_camera_submit(id, CAMERA_TEST_EVF_MODE_OFF, 0, 0);
    if (!strcmp(type, "camera.prepareFocus")) return rig_camera_submit(id, CAMERA_PREPARE_AF, 0, 0);
    if (!strcmp(type, "camera.focusPoint")) {
        cJSON *x = cJSON_GetObjectItemCaseSensitive(payload, "x"), *y = cJSON_GetObjectItemCaseSensitive(payload, "y");
        if (!cJSON_IsNumber(x) || !cJSON_IsNumber(y) || !isfinite(x->valuedouble) || !isfinite(y->valuedouble) ||
            x->valuedouble < 0 || y->valuedouble < 0 || x->valuedouble > 1 || y->valuedouble > 1) return "focus point must be normalized 0-1";
        return rig_camera_submit(id, CAMERA_AF_POINT, (uint32_t)(x->valuedouble * 10000), (uint32_t)(y->valuedouble * 10000));
    }
    if (!strcmp(type, "camera.autofocus")) return rig_camera_submit(id, CAMERA_AF, 0, 0);
    if (!strcmp(type, "camera.autofocusCancel")) return rig_camera_submit(id, CAMERA_AF_CANCEL, 0, 0);
    if (!strcmp(type, "camera.focusStep")) {
        cJSON *direction = cJSON_GetObjectItemCaseSensitive(payload, "direction");
        cJSON *step = cJSON_GetObjectItemCaseSensitive(payload, "step");
        if (!cJSON_IsString(direction) || (strcmp(direction->valuestring, "near") && strcmp(direction->valuestring, "far")) ||
            !cJSON_IsNumber(step) || step->valuedouble < 1 || step->valuedouble > 3 || floor(step->valuedouble) != step->valuedouble)
            return "focus step requires direction near/far and integer step 1-3";
        return rig_camera_submit(id, CAMERA_FOCUS_STEP, 0, (uint32_t)step->valueint | (!strcmp(direction->valuestring, "far") ? 0x8000 : 0));
    }
    if (!strcmp(type, "camera.set")) {
        cJSON *property = cJSON_GetObjectItemCaseSensitive(payload, "property");
        cJSON *value = cJSON_GetObjectItemCaseSensitive(payload, "value");
        if (!cJSON_IsString(property) || !cJSON_IsNumber(value) || !isfinite(value->valuedouble) ||
            value->valuedouble < 0 || value->valuedouble > UINT32_MAX || floor(value->valuedouble) != value->valuedouble)
            return "camera.set requires property and numeric raw Canon value";
        uint32_t code = !strcmp(property->valuestring, "aperture") ? 0xd101 :
            !strcmp(property->valuestring, "shutter") ? 0xd102 : !strcmp(property->valuestring, "iso") ? 0xd103 :
            !strcmp(property->valuestring, "focusMode") ? 0xd108 : !strcmp(property->valuestring, "afMethod") ? 0xd1ba :
            !strcmp(property->valuestring, "movieServo") ? 0xd179 :
            !strcmp(property->valuestring, "autoPowerOff") ? 0xd114 : 0;
        if (!code) return "unsupported camera property";
        return rig_camera_submit(id, CAMERA_SET, code, (uint32_t)value->valuedouble);
    }
    return "unsupported camera command";
}

static char *handle_message(const char *message, bool usb)
{
    xSemaphoreTake(s_command_lock, portMAX_DELAY);
    cJSON *root = cJSON_Parse(message);
    cJSON *id = root ? cJSON_GetObjectItemCaseSensitive(root, "id") : NULL;
    cJSON *type = root ? cJSON_GetObjectItemCaseSensitive(root, "type") : NULL;
    cJSON *version = root ? cJSON_GetObjectItemCaseSensitive(root, "v") : NULL;
    cJSON *payload = root ? cJSON_GetObjectItemCaseSensitive(root, "payload") : NULL;
    const char *error = NULL;
    if (!cJSON_IsObject(root) || !cJSON_IsString(type) || !cJSON_IsObject(payload) ||
        !cJSON_IsNumber(version) || version->valueint != 1) error = "invalid command";
    else if (!strcmp(type->valuestring, "system.ota") && cJSON_IsString(id) && strlen(id->valuestring) <= 64) {
        bool restart = false;
        error = s_restarting ? "restart pending" : rig_ota_wire(payload, &restart);
        cJSON *reply = cJSON_CreateObject();
        cJSON_AddNumberToObject(reply, "v", 1);
        cJSON_AddStringToObject(reply, "type", "ack");
        cJSON_AddStringToObject(reply, "id", id->valuestring);
        cJSON_AddObjectToObject(reply, "payload");
        cJSON_AddBoolToObject(reply, "ok", error == NULL);
        if (error) cJSON_AddStringToObject(reply, "error", error);
        char *response = cJSON_PrintUnformatted(reply);
        cJSON_Delete(reply);
        cJSON_Delete(root);
        if (restart) s_restarting = true;
        xSemaphoreGive(s_command_lock);
        if (restart && xTaskCreate(restart_task, "ota_restart", 2048, NULL, 3, NULL) != pdPASS) esp_restart();
        return response;
    }
    else if (rig_ota_progress() >= 0 && (!strcmp(type->valuestring, "network.configure") ||
             !strcmp(type->valuestring, "network.scan"))) error = "firmware update in progress";
    else if (!strcmp(type->valuestring, "settings.read")) error = usb ? NULL : "settings require USB";
    else if (!strcmp(type->valuestring, "network.scan")) error = start_scan(usb);
    else if (!strcmp(type->valuestring, "network.configure")) error = configure_network(payload, usb);
    else if (!strcmp(type->valuestring, "presence.update")) error = rig_presence_receive(payload);
    else if (!strcmp(type->valuestring, "homeassistant.configure")) error = rig_homeassistant_configure(payload, usb);
    else if (!strncmp(type->valuestring, "camera.", 7)) error = camera_command(type->valuestring, cJSON_IsString(id) ? id->valuestring : NULL, payload);
    else error = apply_command(root);
    if (usb && !error) {
        if (!s_last_serial_request_us) rig_state_note_activity();
        s_last_serial_request_us = esp_timer_get_time();
    }
    char *state = snapshot_json(cJSON_IsString(id) ? id->valuestring : "reply", "rig.state");
    cJSON *reply = cJSON_Parse(state);
    free(state);
    if (!error && usb && !strcmp(type->valuestring, "settings.read")) {
        cJSON *settings = cJSON_AddObjectToObject(cJSON_GetObjectItemCaseSensitive(reply, "payload"), "usbSettings");
        if (settings) {
            rig_homeassistant_usb_settings(settings);
            char pass[64] = {0};
            if (read_ap_password(pass) == ESP_OK) cJSON_AddStringToObject(settings, "apPassword", pass);
        }
    }
    cJSON_AddBoolToObject(reply, "ok", error == NULL);
    if (error) cJSON_AddStringToObject(reply, "error", error);
    cJSON_AddBoolToObject(reply, "rebooting", s_restarting);
    char *response = cJSON_PrintUnformatted(reply);
    cJSON_Delete(reply);
    cJSON_Delete(root);
    xSemaphoreGive(s_command_lock);
    return response;
}

static void serial_task(void *argument)
{
    (void)argument;
    static EXT_RAM_BSS_ATTR char line[8193];
    size_t used = 0;
    bool overflow = false;
    uint8_t bytes[128];
    while (true) {
        if (rig_ota_progress() >= 0 && xSemaphoreTake(s_command_lock, 0) == pdTRUE) {
            rig_ota_expire();
            xSemaphoreGive(s_command_lock);
        }
        if (s_last_serial_request_us && esp_timer_get_time() - s_last_serial_request_us >= PRESENCE_TTL_MS * 1000LL) {
            s_last_serial_request_us = 0;
            rig_state_note_activity();
        }
        int count = uart_read_bytes(UART_NUM_0, bytes, sizeof(bytes), pdMS_TO_TICKS(100));
        for (int i = 0; i < count; i++) {
            if (bytes[i] == '\r') continue;
            if (bytes[i] == '\n') {
                if (used && !overflow) {
                    line[used] = 0;
                    char *response = handle_message(line, true);
                    // Prefix distinguishes protocol replies from boot and ESP logs.
                    printf("\n@rig %s\n", response);
                    fflush(stdout);
                    free(response);
                }
                memset(line, 0, used);
                used = 0;
                overflow = false;
            } else if (used < sizeof(line) - 1 && !overflow) line[used++] = bytes[i];
            else overflow = true;
        }
    }
}

static void start_serial(void)
{
    const uart_config_t config = {.baud_rate=115200, .data_bits=UART_DATA_8_BITS,
        .parity=UART_PARITY_DISABLE, .stop_bits=UART_STOP_BITS_1,
        .flow_ctrl=UART_HW_FLOWCTRL_DISABLE, .source_clk=UART_SCLK_DEFAULT};
    ESP_ERROR_CHECK(uart_param_config(UART_NUM_0, &config));
    ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0, 8192, 0, 0, NULL, 0));
    ESP_ERROR_CHECK(xTaskCreate(serial_task, "rig_serial", 12288, NULL, 4, NULL) == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_LOGI(TAG, "USB serial command transport ready at 115200 baud");
}

static esp_err_t websocket_handler(httpd_req_t *request)
{
    if (request->method == HTTP_GET) return ESP_OK;
    httpd_ws_frame_t frame = {0};
    frame.type = HTTPD_WS_TYPE_TEXT;
    esp_err_t error = httpd_ws_recv_frame(request, &frame, 0);
    if (error != ESP_OK || frame.len > 4096) return ESP_FAIL;
    frame.payload = calloc(1, frame.len + 1);
    if (!frame.payload) return ESP_ERR_NO_MEM;
    error = httpd_ws_recv_frame(request, &frame, frame.len);
    if (error == ESP_OK) {
        char *response = handle_message((char *)frame.payload, false);
        httpd_ws_frame_t outgoing = {
            .type = HTTPD_WS_TYPE_TEXT,
            .payload = (uint8_t *)response,
            .len = strlen(response),
        };
        error = httpd_ws_send_frame(request, &outgoing);
        free(response);
    }
    free(frame.payload);
    return error;
}

static esp_err_t ota_handler(httpd_req_t *request)
{
    if (xSemaphoreTake(s_command_lock, pdMS_TO_TICKS(500)) != pdTRUE)
        return httpd_resp_send_err(request, HTTPD_400_BAD_REQUEST, "busy");
    const char *error = rig_ota_begin(request->content_len, "http", "");
    if (error) {
        xSemaphoreGive(s_command_lock);
        return httpd_resp_send_err(request, HTTPD_400_BAD_REQUEST, error);
    }
    char buffer[1024];
    size_t remaining = request->content_len;
    while (!error && remaining > 0) {
        int count = httpd_req_recv(request, buffer, remaining < sizeof(buffer) ? remaining : sizeof(buffer));
        if (count <= 0) { error = "upload interrupted"; break; }
        error = rig_ota_write(buffer, count);
        remaining -= count;
    }
    if (!error) error = rig_ota_finish();
    if (error) rig_ota_abort();
    else s_restarting = true;
    xSemaphoreGive(s_command_lock);
    if (error) return httpd_resp_send_err(request, HTTPD_400_BAD_REQUEST, error);
    send_json(request, "{\"ok\":true,\"rebooting\":true}");
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();
    return ESP_OK;
}

static bool start_http_server(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.stack_size = 12288;
    config.max_uri_handlers = 8;
    esp_err_t error = httpd_start(&s_http_server, &config);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "HTTP unavailable: %s; USB recovery remains available", esp_err_to_name(error));
        rig_state_set_test("HTTP START ERROR");
        return false;
    }
    const httpd_uri_t routes[] = {
        {.uri = "/health", .method = HTTP_GET, .handler = health_handler},
        {.uri = "/api/state", .method = HTTP_GET, .handler = health_handler},
        {.uri = "/api/camera/link", .method = HTTP_GET, .handler = camera_link_handler},
        {.uri = "/api/wifi", .method = HTTP_POST, .handler = wifi_config_handler},
        {.uri = "/api/ota", .method = HTTP_POST, .handler = ota_handler},
        {.uri = "/ws", .method = HTTP_GET, .handler = websocket_handler, .is_websocket = true},
    };
    for (size_t i = 0; i < sizeof(routes) / sizeof(routes[0]); i++) {
        ESP_ERROR_CHECK(httpd_register_uri_handler(s_http_server, &routes[i]));
    }
    return true;
}

static void wifi_event(void *argument, esp_event_base_t base, int32_t id, void *data)
{
    (void)argument;
    if (base == WIFI_EVENT && (id == WIFI_EVENT_AP_STACONNECTED || id == WIFI_EVENT_AP_STADISCONNECTED))
        rig_state_note_activity();
    if (strcmp(s_network_mode, "router")) return;
    if ((base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) ||
        (base == IP_EVENT && id == IP_EVENT_STA_LOST_IP)) {
        rig_state_set_wifi(false, "");
        xEventGroupClearBits(s_wifi_events, WIFI_CONNECTED_BIT);
        xEventGroupSetBits(s_wifi_events, WIFI_FAILED_BIT);
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = data;
        char address[16];
        snprintf(address, sizeof(address), IPSTR, IP2STR(&event->ip_info.ip));
        rig_state_set_wifi(true, address);
        xEventGroupClearBits(s_wifi_events, WIFI_FAILED_BIT);
        xEventGroupSetBits(s_wifi_events, WIFI_CONNECTED_BIT);
    }
}

static void wifi_stack_init(void)
{
    if (s_wifi_initialized) return;
    s_wifi_events = xEventGroupCreate();
    configASSERT(s_wifi_events);
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_t *station = esp_netif_create_default_wifi_sta();
    ESP_ERROR_CHECK(esp_netif_set_hostname(station, "lightrig"));
    esp_netif_create_default_wifi_ap();
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, ESP_EVENT_ANY_ID, wifi_event, NULL));
    s_wifi_initialized = true;
}

static void wifi_recovery_task(void *argument)
{
    (void)argument;
    unsigned failures = 0;
    for (;;) {
        // One owner of connection attempts. No dependence on the Mac or MQTT.
        xSemaphoreTake(s_wifi_operation_lock, portMAX_DELAY);
        xEventGroupClearBits(s_wifi_events, WIFI_CONNECTED_BIT | WIFI_FAILED_BIT);
        esp_err_t result = esp_wifi_connect();
        xSemaphoreGive(s_wifi_operation_lock);
        EventBits_t events = result == ESP_OK ? xEventGroupWaitBits(s_wifi_events,
            WIFI_CONNECTED_BIT | WIFI_FAILED_BIT, pdFALSE, pdFALSE, pdMS_TO_TICKS(20000)) : 0;
        if (events & WIFI_CONNECTED_BIT) {
            failures = 0;
            xEventGroupWaitBits(s_wifi_events, WIFI_FAILED_BIT, pdTRUE, pdFALSE, portMAX_DELAY);
        }
        // Also recover from association/DHCP stalls with no disconnect event.
        xSemaphoreTake(s_wifi_operation_lock, portMAX_DELAY);
        rig_state_set_wifi(false, "");
        esp_wifi_disconnect();
        xSemaphoreGive(s_wifi_operation_lock);
        vTaskDelay(pdMS_TO_TICKS(rig_wifi_retry_delay_ms(failures)));
        if (failures < 5) ++failures;
    }
}

static bool load_wifi(char *ssid, size_t ssid_size, char *password, size_t password_size)
{
    nvs_handle_t nvs;
    if (nvs_open(WIFI_NAMESPACE, NVS_READONLY, &nvs) != ESP_OK) return false;
    esp_err_t first = nvs_get_str(nvs, "ssid", ssid, &ssid_size);
    esp_err_t second = nvs_get_str(nvs, "password", password, &password_size);
    nvs_close(nvs);
    return first == ESP_OK && second == ESP_OK && ssid[0];
}

static void start_access_point(void)
{
    uint8_t mac[6];
    ESP_ERROR_CHECK(esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP));
    char ssid[33], password[64] = {0};
    snprintf(ssid, sizeof(ssid), "Light Rig-%02X%02X", mac[4], mac[5]);
    if (read_ap_password(password) != ESP_OK || strlen(password) < 8) {
        ESP_LOGE(TAG, "AP password unavailable; connect over USB");
        return;
    }
    wifi_config_t config = {0};
    strlcpy((char *)config.ap.ssid, ssid, sizeof(config.ap.ssid));
    strlcpy((char *)config.ap.password, password, sizeof(config.ap.password));
    config.ap.ssid_len = strlen(ssid);
    config.ap.channel = 1;
    config.ap.max_connection = 4;
    config.ap.authmode = WIFI_AUTH_WPA2_PSK;
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &config));
    ESP_ERROR_CHECK(esp_wifi_start());
    rig_state_set_wifi(false, "192.168.4.1");
    ESP_LOGW(TAG, "provisioning AP %s started", ssid);
}

static void start_station(const char *ssid, const char *password)
{
    strlcpy(s_station_ssid, ssid, sizeof(s_station_ssid));
    wifi_config_t config = {0};
    strlcpy((char *)config.sta.ssid, ssid, sizeof(config.sta.ssid));
    strlcpy((char *)config.sta.password, password, sizeof(config.sta.password));
    config.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &config));
    ESP_ERROR_CHECK(esp_wifi_start());
}

bool rig_network_init(void)
{
    s_command_lock = xSemaphoreCreateMutex();
    s_wifi_operation_lock = xSemaphoreCreateMutex();
    s_wifi_scan_lock = xSemaphoreCreateMutex();
    configASSERT(s_command_lock && s_wifi_operation_lock && s_wifi_scan_lock);
    nvs_handle_t settings;
    if (nvs_open(WIFI_NAMESPACE, NVS_READONLY, &settings) == ESP_OK) {
        size_t length = sizeof(s_network_mode);
        if (nvs_get_str(settings, "mode", s_network_mode, &length) != ESP_OK) {
            char ssid[33] = {0}, password[64] = {0};
            strlcpy(s_network_mode, load_wifi(ssid, sizeof(ssid), password, sizeof(password)) ? "router" : "usb", sizeof(s_network_mode));
        }
        nvs_close(settings);
    }
    start_serial(); // Recovery transport must start before Wi-Fi/HTTP.
    if (!strcmp(s_network_mode, "usb")) {
        rig_state_set_wifi(false, "USB");
        return true;
    }
    wifi_stack_init();

    char ssid[33] = {0}, password[64] = {0};
    if (!strcmp(s_network_mode, "router") && load_wifi(ssid, sizeof(ssid), password, sizeof(password))) start_station(ssid, password);
    else {
        strlcpy(s_network_mode, "ap", sizeof(s_network_mode));
        start_access_point();
    }

    ESP_ERROR_CHECK(mdns_init());
    ESP_ERROR_CHECK(mdns_hostname_set("lightrig"));
    ESP_ERROR_CHECK(mdns_instance_name_set("Light Rig"));
    ESP_ERROR_CHECK(mdns_service_add("Light Rig", "_canonrig", "_tcp", 80, NULL, 0));
    bool server_ready = start_http_server();
    if (!strcmp(s_network_mode, "router"))
        configASSERT(xTaskCreate(wifi_recovery_task, "wifi_recovery", 3072, NULL, 2, NULL) == pdPASS);
    return server_ready;
}
