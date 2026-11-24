#include "rig_ota.h"
#include "rig_homeassistant.h"
#include "rig_state.h"
#include "esp_app_desc.h"
#include "esp_ota_ops.h"
#include "esp_timer.h"
#include "mbedtls/base64.h"
#include <stdatomic.h>
#include <string.h>

static esp_ota_handle_t handle;
static const esp_partition_t *destination;
static size_t total, written;
static char owner[37], version[32];
static int64_t last_write;
static atomic_int progress = -1;

int rig_ota_progress(void) { return atomic_load(&progress); }

void rig_ota_abort(void)
{
    if (handle) esp_ota_abort(handle);
    handle = 0;
    atomic_store(&progress, -1);
}

static bool busy(void)
{
    rig_mode_t mode = rig_state_get().mode;
    return mode == RIG_ON_CALL || mode == RIG_PREVIEW;
}

const char *rig_ota_begin(size_t size, const char *session, const char *target)
{
    if (rig_ota_progress() >= 0 || busy()) return "controller busy";
    destination = esp_ota_get_next_update_partition(NULL);
    if (!destination || size < 288 || size > destination->size) return "invalid image size";
    total = size;
    written = 0;
    strlcpy(owner, session, sizeof(owner));
    strlcpy(version, target, sizeof(version));
    atomic_store(&progress, 0);
    if (esp_ota_begin(destination, OTA_WITH_SEQUENTIAL_WRITES, &handle) != ESP_OK) {
        handle = 0;
        atomic_store(&progress, -1);
        return "cannot open OTA partition";
    }
    last_write = esp_timer_get_time();
    return NULL;
}

const char *rig_ota_write(const void *data, size_t size)
{
    if (!handle || !size || size > total - written) return "invalid firmware chunk";
    if (busy() || esp_ota_write(handle, data, size) != ESP_OK) {
        rig_ota_abort();
        return "firmware transfer interrupted";
    }
    written += size;
    last_write = esp_timer_get_time();
    atomic_store(&progress, (int)(99 * written / total));
    return NULL;
}

const char *rig_ota_finish(void)
{
    if (!handle || written != total || busy()) {
        rig_ota_abort();
        return "incomplete or busy";
    }
    esp_err_t error = esp_ota_end(handle);
    handle = 0; // esp_ota_end releases this handle on both success and failure.
    esp_app_desc_t desc;
    if (error == ESP_OK) error = esp_ota_get_partition_description(destination, &desc);
    if (error != ESP_OK || strncmp(desc.project_name, esp_app_get_description()->project_name, sizeof(desc.project_name)) ||
        (version[0] && strncmp(version, desc.version, sizeof(desc.version))) ||
        esp_ota_set_boot_partition(destination) != ESP_OK) {
        atomic_store(&progress, -1);
        return "image validation failed";
    }
    atomic_store(&progress, 100);
    return NULL;
}

void rig_ota_expire(void)
{
    if (handle && esp_timer_get_time() - last_write > 20000000) rig_ota_abort();
}

static const char *string(cJSON *payload, const char *key)
{
    const cJSON *value = cJSON_GetObjectItemCaseSensitive(payload, key);
    return cJSON_IsString(value) ? value->valuestring : "";
}

const char *rig_ota_wire(cJSON *p, bool *restart)
{
    const char *op = string(p, "op"), *session = string(p, "session");
    if (strlen(session) != 36) return "invalid OTA session";
    if (!strcmp(op, "begin")) {
        const char *target = string(p, "target");
        cJSON *size = cJSON_GetObjectItemCaseSensitive(p, "size");
        if (strcmp(string(p, "device"), rig_homeassistant_device_id()) ||
            strcmp(string(p, "from"), esp_app_get_description()->version) ||
            !target[0] || strlen(target) >= sizeof(version) ||
            !cJSON_IsNumber(size) || size->valueint != size->valuedouble || size->valueint <= 0)
            return "firmware target mismatch";
        return rig_ota_begin(size->valueint, session, target);
    }
    if (!handle || strcmp(owner, session)) return "inactive OTA session";
    if (!strcmp(op, "abort")) { rig_ota_abort(); return NULL; }
    if (!strcmp(op, "finish")) {
        const char *error = rig_ota_finish();
        *restart = error == NULL;
        return error;
    }
    cJSON *offset = cJSON_GetObjectItemCaseSensitive(p, "offset");
    if (strcmp(op, "write") || !cJSON_IsNumber(offset) || offset->valuedouble != written) return "unexpected firmware offset";
    unsigned char bytes[1536];
    size_t count = 0;
    const char *encoded = string(p, "data");
    if (mbedtls_base64_decode(bytes, sizeof(bytes), &count, (const unsigned char *)encoded, strlen(encoded)) != 0)
        return "bad firmware data";
    return rig_ota_write(bytes, count);
}
