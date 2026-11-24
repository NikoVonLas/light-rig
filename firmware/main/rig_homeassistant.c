#include "esp_attr.h"
#include "rig_homeassistant.h"
#include "rig_presence.h"
#include "rig_state.h"
#include "mqtt_client.h"
#include "mbedtls/x509_crt.h"
#include <stddef.h>
#include "esp_mac.h"
#include "esp_timer.h"
#include "esp_crt_bundle.h"
#include "esp_netif_sntp.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"
#include "nvs.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Keep this prefix compatible with the original public_v1 NVS record.
typedef struct { char host[128]; uint16_t port; bool tls, auth, enabled; } ha_config_t;
typedef struct {
    ha_config_t config;
    char user[65], password[129], ca[3073];
} ha_settings_t;
static EXT_RAM_BSS_ATTR ha_settings_t s_settings;
static unsigned s_revision;
static SemaphoreHandle_t s_lock;
static EventGroupHandle_t s_events;
static char s_device[40], s_base[64], s_availability[96];
#define ONLINE BIT0
#define DISCOVERY BIT1
#define LOST BIT2

static bool valid_host(const char *host) {
    if (!host || !*host || strlen(host) > 127) return false;
    for (const char *p = host; *p; p++) if (!( (*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
        (*p >= '0' && *p <= '9') || *p == '.' || *p == '-')) return false;
    return true;
}
const char *rig_homeassistant_configure(cJSON *p, bool usb) {
    if (!usb) return "MQTT configuration requires USB";
    cJSON *enabled = cJSON_GetObjectItemCaseSensitive(p, "enabled");
    cJSON *host = cJSON_GetObjectItemCaseSensitive(p, "host"), *port = cJSON_GetObjectItemCaseSensitive(p, "port");
    cJSON *tls = cJSON_GetObjectItemCaseSensitive(p, "tls"), *user = cJSON_GetObjectItemCaseSensitive(p, "username");
    cJSON *password = cJSON_GetObjectItemCaseSensitive(p, "password");
    if (!cJSON_IsBool(enabled)) return "enabled must be boolean";
    ha_settings_t *next = calloc(1, sizeof(*next));
    if (!next) return "out of memory";
    cJSON *ca = cJSON_GetObjectItemCaseSensitive(p, "caPEM");
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *next = s_settings;
    next->config.enabled = cJSON_IsTrue(enabled);
    const char *failure = NULL;
    if (next->config.enabled) {
        if (!cJSON_IsString(host) || !valid_host(host->valuestring) || !cJSON_IsNumber(port) ||
            !isfinite(port->valuedouble) || floor(port->valuedouble) != port->valuedouble ||
            port->valuedouble < 1 || port->valuedouble > 65535 || !cJSON_IsBool(tls)) {
            failure = "invalid MQTT host/port/tls"; goto done;
        }
        if ((user && (!cJSON_IsString(user) || strlen(user->valuestring) >= sizeof(next->user))) ||
            (password && (!cJSON_IsString(password) || strlen(password->valuestring) >= sizeof(next->password)))) {
            failure = "invalid MQTT credentials"; goto done;
        }
        // Omitted password reuses the old one only for the same destination and user.
        if (user && *user->valuestring) {
            if (!cJSON_IsTrue(tls)) { failure = "credentials require TLS"; goto done; }
            if (password) {
                memset(next->password, 0, sizeof(next->password));
                strlcpy(next->password, password->valuestring, sizeof(next->password));
            }
            else if (strcmp(next->user, user->valuestring) || strcmp(next->config.host, host->valuestring) ||
                     next->config.port != port->valueint || !next->password[0]) {
                failure = "enter password for this broker and user"; goto done;
            }
            strlcpy(next->user, user->valuestring, sizeof(next->user));
        } else {
            if (password && *password->valuestring) { failure = "username required"; goto done; }
            memset(next->user, 0, sizeof(next->user)); memset(next->password, 0, sizeof(next->password));
        }
        if (ca) {
            if (!cJSON_IsString(ca) || strlen(ca->valuestring) >= sizeof(next->ca)) {
                failure = "invalid CA certificate size"; goto done;
            }
            if (*ca->valuestring) {
                mbedtls_x509_crt cert;
                mbedtls_x509_crt_init(&cert);
                bool valid = cJSON_IsTrue(tls) && !strncmp(ca->valuestring, "-----BEGIN CERTIFICATE-----", 27) &&
                    !strstr(ca->valuestring, "PRIVATE KEY") &&
                    mbedtls_x509_crt_parse(&cert, (const unsigned char *)ca->valuestring, strlen(ca->valuestring)+1) == 0;
                mbedtls_x509_crt_free(&cert);
                if (!valid) { failure = "invalid TLS CA certificate"; goto done; }
            }
            strlcpy(next->ca, ca->valuestring, sizeof(next->ca));
        }
        strlcpy(next->config.host, host->valuestring, sizeof(next->config.host));
        next->config.port = port->valueint; next->config.tls = cJSON_IsTrue(tls);
        next->config.auth = next->user[0] != 0;
    }
    nvs_handle_t nvs;
    esp_err_t error = nvs_open("homeassistant", NVS_READWRITE, &nvs);
    if (error == ESP_OK) {
        error = nvs_set_blob(nvs, "settings_v2", next, offsetof(ha_settings_t, ca) + strlen(next->ca) + 1);
        if (error == ESP_OK) error = nvs_commit(nvs);
        nvs_close(nvs);
    }
    if (error == ESP_OK) { s_settings = *next; s_revision++; rig_state_note_activity(); }
    else failure = "MQTT configuration save failed";
done:
    xSemaphoreGive(s_lock);
    free(next);
    return failure;
}

void rig_homeassistant_usb_settings(cJSON *p) {
    xSemaphoreTake(s_lock, portMAX_DELAY);
    cJSON_AddStringToObject(p, "username", s_settings.user);
    cJSON_AddStringToObject(p, "caPEM", s_settings.ca);
    xSemaphoreGive(s_lock);
}

const char *rig_homeassistant_device_id(void) { return s_device; }

void rig_homeassistant_json(cJSON *parent) {
    xSemaphoreTake(s_lock, portMAX_DELAY);
    cJSON *p = cJSON_AddObjectToObject(parent, "homeAssistant");
    cJSON_AddBoolToObject(p, "enabled", s_settings.config.enabled);
    cJSON_AddBoolToObject(p, "connected", (xEventGroupGetBits(s_events) & ONLINE) != 0);
    cJSON_AddStringToObject(p, "host", s_settings.config.host);
    cJSON_AddNumberToObject(p, "port", s_settings.config.port);
    cJSON_AddBoolToObject(p, "tls", s_settings.config.tls);
    cJSON_AddBoolToObject(p, "requiresAuth", s_settings.config.auth);
    cJSON_AddBoolToObject(p, "needsCredentials", s_settings.config.auth && !s_settings.user[0]);
    cJSON_AddBoolToObject(p, "credentialsPersistent", true);
    cJSON_AddStringToObject(p, "deviceId", s_device);
    xSemaphoreGive(s_lock);
}
static void event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    esp_mqtt_event_handle_t e = data;
    if (id == MQTT_EVENT_CONNECTED) {
        if (!(xEventGroupGetBits(s_events) & ONLINE)) rig_state_note_activity();
        xEventGroupSetBits(s_events, ONLINE | DISCOVERY);
        esp_mqtt_client_subscribe(e->client, "homeassistant/status", 1);
    } else if (id == MQTT_EVENT_DISCONNECTED) {
        if (xEventGroupClearBits(s_events, ONLINE) & ONLINE) rig_state_note_activity();
        xEventGroupSetBits(s_events, LOST);
    }
    else if (id == MQTT_EVENT_DATA && e->topic_len == 20 && !memcmp(e->topic, "homeassistant/status", 20) &&
        e->data_len == 6 && !memcmp(e->data, "online", 6)) xEventGroupSetBits(s_events, DISCOVERY);
}
static bool publish(esp_mqtt_client_handle_t client, const char *topic, const char *payload, bool retain) {
    // Called only when connected, bounded outbox. No offline state backlog.
    return esp_mqtt_client_enqueue(client, topic, payload, 0, 1, retain, true) >= 0;
}
static bool discover(esp_mqtt_client_handle_t client, const char *key, const char *name) {
    char topic[180], unique[100], state[150], available[150];
    snprintf(unique, sizeof(unique), "%s_%s", s_device, key);
    snprintf(topic, sizeof(topic), "homeassistant/binary_sensor/%s/%s/config", s_device, key);
    snprintf(state, sizeof(state), "%s/%s/state", s_base, key);
    snprintf(available, sizeof(available), "%s/%s/available", s_base, key);
    cJSON *p = cJSON_CreateObject();
    cJSON_AddStringToObject(p, "unique_id", unique); cJSON_AddStringToObject(p, "name", name);
    cJSON_AddStringToObject(p, "state_topic", state);
    cJSON_AddStringToObject(p, "icon", strstr(key, "camera") ? "mdi:video" : "mdi:phone-in-talk");
    cJSON_AddNumberToObject(p, "expire_after", 15);
    cJSON_AddStringToObject(p, "availability_mode", "all");
    cJSON *a = cJSON_AddArrayToObject(p, "availability");
    cJSON *broker = cJSON_CreateObject(); cJSON_AddStringToObject(broker, "topic", s_availability); cJSON_AddItemToArray(a, broker);
    cJSON *source = cJSON_CreateObject(); cJSON_AddStringToObject(source, "topic", available); cJSON_AddItemToArray(a, source);
    cJSON *d = cJSON_AddObjectToObject(p, "device");
    cJSON_AddStringToObject(d, "identifiers", s_device); cJSON_AddStringToObject(d, "name", "Light Rig");
    cJSON_AddStringToObject(d, "manufacturer", "Light Rig"); cJSON_AddStringToObject(d, "model", "Light Rig (T8 ESP32-S2)");
    char *json = cJSON_PrintUnformatted(p); bool ok = json && publish(client, topic, json, true);
    free(json); cJSON_Delete(p); return ok;
}
static void sensor(esp_mqtt_client_handle_t client, const char *key, bool fresh, int value, int *availability) {
    char topic[150]; snprintf(topic, sizeof(topic), "%s/%s/available", s_base, key);
    if (*availability != (int)fresh && publish(client, topic, fresh ? "online" : "offline", true)) *availability = fresh;
    if (fresh) {
        snprintf(topic, sizeof(topic), "%s/%s/state", s_base, key);
        // Non-retained live states + expire_after prevent stale state on HA restart.
        publish(client, topic, value < 0 ? "None" : value ? "ON" : "OFF", false);
    }
}
static void mqtt_task(void *arg) {
    esp_mqtt_client_handle_t client = NULL; unsigned revision = 0;
    char known_names[PRESENCE_CLIENTS][49] = {0}; bool discovered = false, time_started = false;
    int availability[2 + 2 * PRESENCE_CLIENTS];
    for (int i = 0; i < 2 + 2 * PRESENCE_CLIENTS; i++) availability[i] = -1;
    bool announced = false;
    for (;;) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        ha_config_t config = s_settings.config; unsigned current = s_revision;
        char user[65], password[129]; memcpy(user, s_settings.user, sizeof(user)); memcpy(password, s_settings.password, sizeof(password));
        xSemaphoreGive(s_lock);
        if (client && (revision != current || (xEventGroupGetBits(s_events) & LOST))) {
            if (xEventGroupGetBits(s_events) & ONLINE) esp_mqtt_client_publish(client, s_availability, "offline", 0, 1, true);
            esp_mqtt_client_stop(client); esp_mqtt_client_destroy(client); client = NULL;
            // Destroy the old outbox too: never replay stale ON/OFF after reconnect.
            xEventGroupClearBits(s_events, ONLINE | DISCOVERY | LOST); discovered = false;
            announced = false;
            for (int i = 0; i < 2 + 2 * PRESENCE_CLIENTS; i++) availability[i] = -1;
        }
        if (!client && config.enabled && (!config.auth || user[0]) && rig_state_get().wifi_connected) {
            if (config.tls && !time_started) {
                esp_sntp_config_t time_config = ESP_NETIF_SNTP_DEFAULT_CONFIG("pool.ntp.org");
                time_started = esp_netif_sntp_init(&time_config) == ESP_OK;
            }
            char uri[180]; snprintf(uri, sizeof(uri), "%s://%s:%u", config.tls ? "mqtts" : "mqtt", config.host, config.port);
            // The MQTT library borrows the certificate until its client is destroyed.
            static EXT_RAM_BSS_ATTR char active_ca[sizeof(s_settings.ca)];
            xSemaphoreTake(s_lock, portMAX_DELAY);
            bool current_config = current == s_revision;
            strlcpy(active_ca, s_settings.ca, sizeof(active_ca));
            xSemaphoreGive(s_lock);
            if (!current_config) continue;
            esp_mqtt_client_config_t c = {
                .broker.address.uri = uri,
                .broker.verification.certificate = config.tls && active_ca[0] ? active_ca : NULL,
                .broker.verification.crt_bundle_attach = config.tls && !active_ca[0] ? esp_crt_bundle_attach : NULL,
                .credentials.client_id = s_device,
                .credentials.username = config.auth ? user : NULL,
                .credentials.authentication.password = config.auth ? password : NULL,
                .session.keepalive = 10,
                .session.last_will = {.topic = s_availability, .msg = "offline", .qos = 1, .retain = true},
                .network.timeout_ms = 3000,
                .outbox.limit = 16384,
            };
            client = esp_mqtt_client_init(&c); revision = current;
            if (client) {
                esp_mqtt_client_register_event(client, ESP_EVENT_ANY_ID, event, NULL);
                if (esp_mqtt_client_start(client) != ESP_OK) { esp_mqtt_client_destroy(client); client = NULL; }
            }
        }
        memset(user, 0, sizeof(user)); memset(password, 0, sizeof(password));
        if (client && (xEventGroupGetBits(s_events) & ONLINE)) {
            presence_model_t model = rig_presence_get(); int64_t now = esp_timer_get_time() / 1000;
            presence_summary_t summary = presence_summary(&model, now);
            EventBits_t events = xEventGroupClearBits(s_events, DISCOVERY);
            if (events & DISCOVERY) discovered = false;
            for (int i = 0; i < PRESENCE_CLIENTS; i++) if (strcmp(known_names[i], model.clients[i].name)) discovered = false;
            if (!discovered) {
                bool ok = discover(client, "call", "На звонке") & discover(client, "camera", "Камера в звонке");
                for (int i = 0; i < PRESENCE_CLIENTS; i++) if (model.clients[i].id[0]) {
                    char key[64], name[100];
                    snprintf(key, sizeof(key), "%s_call", model.clients[i].id); snprintf(name, sizeof(name), "%s — звонок", model.clients[i].name);
                    ok &= discover(client, key, name);
                    snprintf(key, sizeof(key), "%s_camera", model.clients[i].id); snprintf(name, sizeof(name), "%s — камера в звонке", model.clients[i].name);
                    ok &= discover(client, key, name);
                    strcpy(known_names[i], model.clients[i].name);
                }
                discovered = ok;
            }
            if (!announced) announced = publish(client, s_availability, "online", true);
            sensor(client, "call", summary.available, summary.call, &availability[0]);
            sensor(client, "camera", summary.available, summary.camera, &availability[1]);
            for (int i = 0; i < PRESENCE_CLIENTS; i++) if (model.clients[i].id[0]) {
                char key[64]; bool fresh = presence_fresh(&model.clients[i], now);
                snprintf(key, sizeof(key), "%s_call", model.clients[i].id); sensor(client, key, fresh, model.clients[i].on_call, &availability[2 + 2*i]);
                snprintf(key, sizeof(key), "%s_camera", model.clients[i].id); sensor(client, key, fresh, model.clients[i].camera, &availability[3 + 2*i]);
            }
        }
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}
void rig_homeassistant_init(void) {
    s_lock = xSemaphoreCreateMutex(); s_events = xEventGroupCreate(); configASSERT(s_lock && s_events);
    uint8_t mac[6]; ESP_ERROR_CHECK(esp_read_mac(mac, ESP_MAC_WIFI_STA));
    snprintf(s_device, sizeof(s_device), "canonrig_%02x%02x%02x%02x%02x%02x", mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);
    snprintf(s_base, sizeof(s_base), "canonrig/%s", s_device); snprintf(s_availability, sizeof(s_availability), "%s/availability", s_base);
    nvs_handle_t nvs;
    if (nvs_open("homeassistant", NVS_READONLY, &nvs) == ESP_OK) {
        size_t size = sizeof(s_settings);
        esp_err_t error = nvs_get_blob(nvs, "settings_v2", &s_settings, &size);
        if (error == ESP_ERR_NVS_NOT_FOUND) {
            size = sizeof(s_settings.config);
            if (nvs_get_blob(nvs, "public_v1", &s_settings.config, &size) != ESP_OK || size != sizeof(s_settings.config))
                memset(&s_settings, 0, sizeof(s_settings));
        } else if (error != ESP_OK || size <= offsetof(ha_settings_t, ca) || size > sizeof(s_settings)) {
            memset(&s_settings, 0, sizeof(s_settings));
        }
        s_settings.config.host[127] = s_settings.user[64] = s_settings.password[128] = s_settings.ca[3072] = 0;
        if (s_settings.config.enabled && (!valid_host(s_settings.config.host) || !s_settings.config.port))
            memset(&s_settings, 0, sizeof(s_settings));
        nvs_close(nvs);
    }
    configASSERT(xTaskCreate(mqtt_task, "homeassistant", 8192, NULL, 3, NULL) == pdPASS);
}
