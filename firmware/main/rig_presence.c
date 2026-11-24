#include "rig_presence.h"
#include "rig_light.h"
#include "rig_state.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "nvs.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static presence_model_t s_model;
static SemaphoreHandle_t s_lock;
static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }
presence_model_t rig_presence_get(void) {
    xSemaphoreTake(s_lock, portMAX_DELAY); presence_model_t r = s_model;
    xSemaphoreGive(s_lock); return r;
}
const char *rig_presence_receive(cJSON *p) {
    cJSON *id = cJSON_GetObjectItemCaseSensitive(p, "clientId"), *name = cJSON_GetObjectItemCaseSensitive(p, "name");
    cJSON *session = cJSON_GetObjectItemCaseSensitive(p, "session"), *seq = cJSON_GetObjectItemCaseSensitive(p, "sequence");
    cJSON *call = cJSON_GetObjectItemCaseSensitive(p, "onCall"), *camera = cJSON_GetObjectItemCaseSensitive(p, "cameraInCall");
    cJSON *automatic = cJSON_GetObjectItemCaseSensitive(p, "automatic"), *preview = cJSON_GetObjectItemCaseSensitive(p, "preview");
    if (!cJSON_IsString(id) || !cJSON_IsString(name) || !cJSON_IsString(session) || !cJSON_IsNumber(seq) ||
        !isfinite(seq->valuedouble) || seq->valuedouble < 0 || seq->valuedouble > UINT32_MAX || floor(seq->valuedouble) != seq->valuedouble ||
        !cJSON_IsBool(call) || (!cJSON_IsNull(camera) && !cJSON_IsBool(camera)) ||
        !cJSON_IsBool(automatic) || !cJSON_IsBool(preview)) return "invalid presence payload";
    xSemaphoreTake(s_lock, portMAX_DELAY);
    presence_model_t next = s_model;
    const char *error = presence_update(&next, id->valuestring, name->valuestring, session->valuestring,
        (uint32_t)seq->valuedouble, cJSON_IsTrue(call), cJSON_IsNull(camera) ? -1 : cJSON_IsTrue(camera),
        cJSON_IsTrue(automatic), cJSON_IsTrue(preview), now_ms());
    if (!error) {
        bool changed = false;
        for (int i = 0; i < PRESENCE_CLIENTS; i++) changed |= strcmp(next.clients[i].id, s_model.clients[i].id) || strcmp(next.clients[i].name, s_model.clients[i].name);
        if (changed) {
            // Persist public identity only, never live status/session or credentials.
            presence_model_t saved = {0};
            for (int i = 0; i < PRESENCE_CLIENTS; i++) {
                strcpy(saved.clients[i].id, next.clients[i].id); strcpy(saved.clients[i].name, next.clients[i].name);
            }
            nvs_handle_t nvs;
            if (nvs_open("presence", NVS_READWRITE, &nvs) != ESP_OK) error = "presence NVS open failed";
            else {
                if (nvs_set_blob(nvs, "clients_v1", &saved, sizeof(saved)) != ESP_OK || nvs_commit(nvs) != ESP_OK) error = "presence NVS save failed";
                nvs_close(nvs);
            }
        }
        if (!error) {
            for (int i = 0; i < PRESENCE_CLIENTS; i++) {
                const presence_client_t *a = &s_model.clients[i], *b = &next.clients[i];
                if (changed || a->on_call != b->on_call || a->camera != b->camera ||
                    a->automatic != b->automatic || a->preview != b->preview) {
                    rig_state_note_activity();
                    break;
                }
            }
            s_model = next;
        }
    }
    xSemaphoreGive(s_lock); return error;
}
void rig_presence_json(cJSON *parent) {
    presence_model_t model = rig_presence_get(); presence_summary_t r = presence_summary(&model, now_ms());
    cJSON *p = cJSON_AddObjectToObject(parent, "presence");
    cJSON_AddBoolToObject(p, "available", r.available);
    if (r.call < 0) cJSON_AddNullToObject(p, "onCall"); else cJSON_AddBoolToObject(p, "onCall", r.call);
    if (r.camera < 0) cJSON_AddNullToObject(p, "cameraInCall"); else cJSON_AddBoolToObject(p, "cameraInCall", r.camera);
    cJSON *clients = cJSON_AddArrayToObject(p, "clients");
    for (int i = 0; i < PRESENCE_CLIENTS; i++) if (model.clients[i].id[0]) {
        presence_client_t *c = &model.clients[i]; bool fresh = presence_fresh(c, now_ms());
        cJSON *entry = cJSON_CreateObject(); cJSON_AddItemToArray(clients, entry);
        cJSON_AddStringToObject(entry, "id", c->id); cJSON_AddStringToObject(entry, "name", c->name);
        cJSON_AddBoolToObject(entry, "available", fresh);
        if (fresh) cJSON_AddBoolToObject(entry, "onCall", c->on_call); else cJSON_AddNullToObject(entry, "onCall");
        if (fresh && c->camera >= 0) cJSON_AddBoolToObject(entry, "cameraInCall", c->camera); else cJSON_AddNullToObject(entry, "cameraInCall");
    }
}
static void presence_task(void *arg) {
    bool controlled = false;
    bool online[PRESENCE_CLIENTS] = {0};
    for (;;) {
        presence_model_t model = rig_presence_get(); presence_summary_t r = presence_summary(&model, now_ms());
        for (int i = 0; i < PRESENCE_CLIENTS; i++) {
            bool fresh = presence_fresh(&model.clients[i], now_ms());
            if (fresh != online[i]) rig_state_note_activity();
            online[i] = fresh;
        }
        if (model.clients[0].id[0] || model.clients[1].id[0]) {
            rig_mode_t mode = r.call == 1 ? RIG_ON_CALL : r.preview ? RIG_PREVIEW : RIG_IDLE;
            if (rig_state_get().mode != mode) rig_state_set_mode(mode);
            if (r.automate && !controlled) { controlled = rig_light_apply_preset(LIGHT_CALL_PRESET); }
            else if (!r.automate && controlled) {
                light_command_t light = rig_light_get_command(); light.enabled = false; rig_light_apply(&light); controlled = false;
            }
        }
        vTaskDelay(pdMS_TO_TICKS(250));
    }
}
void rig_presence_init(void) {
    s_lock = xSemaphoreCreateMutex(); configASSERT(s_lock);
    nvs_handle_t nvs;
    if (nvs_open("presence", NVS_READONLY, &nvs) == ESP_OK) {
        size_t size = sizeof(s_model);
        if (nvs_get_blob(nvs, "clients_v1", &s_model, &size) != ESP_OK || size != sizeof(s_model)) memset(&s_model, 0, sizeof(s_model));
        nvs_close(nvs);
        for (int i = 0; i < PRESENCE_CLIENTS; i++) { s_model.clients[i].received = false; s_model.clients[i].id[36] = 0; s_model.clients[i].name[48] = 0; }
    }
    configASSERT(xTaskCreate(presence_task, "presence", 4096, NULL, 3, NULL) == pdPASS);
}
