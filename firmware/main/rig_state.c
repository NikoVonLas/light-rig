#include "rig_state.h"

#include <string.h>
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

static rig_snapshot_t s_state;
static eos_exposure_t s_exposure;
static SemaphoreHandle_t s_lock;

static bool copy_string(char *target, size_t target_size, const char *source)
{
    if (!source) source = "";
    if (!strncmp(target, source, target_size - 1)) return false;
    strlcpy(target, source, target_size);
    return true;
}

void rig_state_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    s_state = (rig_snapshot_t) {
        .mode = RIG_IDLE,
        .camera_connected = false,
        .light_ready = false,
        .light_brightness = 60,
        .light_preset = 0,
        .revision = 1,
    };
    copy_string(s_state.camera_status, sizeof(s_state.camera_status), "PTP waiting");
    copy_string(s_state.light_effect, sizeof(s_state.light_effect), "solid");
}

rig_snapshot_t rig_state_get(void)
{
    rig_snapshot_t copy;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    copy = s_state;
    xSemaphoreGive(s_lock);
    return copy;
}

void rig_state_note_activity(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_state.revision++;
    xSemaphoreGive(s_lock);
}

void rig_state_set_mode(rig_mode_t mode)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_state.mode != mode) s_state.revision++;
    s_state.mode = mode;
    xSemaphoreGive(s_lock);
}

void rig_state_set_wifi(bool connected, const char *ip_address)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool changed = copy_string(s_state.ip_address, sizeof(s_state.ip_address), ip_address);
    if (changed || s_state.wifi_connected != connected) s_state.revision++;
    s_state.wifi_connected = connected;
    xSemaphoreGive(s_lock);
}

void rig_state_set_camera_usb_line(bool attached)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_state.camera_usb_line_attached != attached) s_state.revision++;
    s_state.camera_usb_line_attached = attached;
    xSemaphoreGive(s_lock);
}

void rig_state_count_camera_port_restart(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_state.camera_port_restarts++;
    xSemaphoreGive(s_lock);
}

void rig_state_set_camera(bool connected, const char *status)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool changed = copy_string(s_state.camera_status, sizeof(s_state.camera_status), status);
    if (changed || s_state.camera_connected != connected) s_state.revision++;
    s_state.camera_connected = connected;
    xSemaphoreGive(s_lock);
}

void rig_state_set_camera_info(const ptp_device_info_t *info)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (memcmp(&s_state.camera_info, info, sizeof(*info))) s_state.revision++;
    s_state.camera_info = *info;
    xSemaphoreGive(s_lock);
}

void rig_state_set_camera_polling_paused(bool paused)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_state.camera_polling_paused != paused) s_state.revision++;
    s_state.camera_polling_paused = paused;
    xSemaphoreGive(s_lock);
}

void rig_state_set_exposure(const eos_exposure_t *exposure)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_state.camera_exposure_line[0] && !memcmp(&s_exposure, exposure, sizeof(*exposure))) {
        xSemaphoreGive(s_lock);
        return;
    }
    s_exposure = *exposure;
    // Values are Canon codes, not ordinary ISO/f-numbers. Map verified third
    // stops for the compact LCD; show raw codes explicitly outside these tables.
    static const char *apertures[] = {"1.4","1.6","1.8","2","2.2","2.5","2.8","3.2","3.5","4","4.5","5","5.6","6.3","7.1","8","9","10","11","13","14","16"};
    static const char *shutters[] = {"8","10","13","15","20","25","30","40","50","60","80","100","125","160","200","250","320","400","500","640","800","1000","1250","1600","2000","2500","3200","4000"};
    static const char *isos[] = {"100","125","160","200","250","320","400","500","640","800","1000","1250","1600","2000","2500","3200","4000","5000","6400"};
    const eos_property_t *properties[] = {&exposure->aperture, &exposure->shutter, &exposure->iso};
    const char **tables[] = {apertures, shutters, isos};
    const unsigned bases[] = {0x10,0x50,0x48}, counts[] = {22,28,19};
    const char *prefixes[] = {"F","1/","ISO "};
    char labels[3][14];
    for (unsigned i = 0; i < 3; i++) {
        const eos_property_t *property = properties[i];
        snprintf(labels[i], sizeof(labels[i]), "%s--", prefixes[i]);
        if (!property->known) continue;
        if (property->value == 0) { snprintf(labels[i], sizeof(labels[i]), "%sAUTO", prefixes[i]); continue; }
        uint32_t delta = property->value - bases[i], fraction = delta % 8;
        uint32_t index = delta / 8 * 3 + (fraction == 3 ? 1 : fraction == 5 ? 2 : 0);
        if (property->value >= bases[i] && (fraction == 0 || fraction == 3 || fraction == 5) && index < counts[i])
            snprintf(labels[i], sizeof(labels[i]), "%s%s", prefixes[i], tables[i][index]);
        else snprintf(labels[i], sizeof(labels[i]), "0X%lX", (unsigned long)property->value);
    }
    snprintf(s_state.camera_exposure_line, sizeof(s_state.camera_exposure_line), "%.12s %.12s %.12s", labels[0], labels[1], labels[2]);
    const char *af = !exposure->af_method.known ? "--" : exposure->af_method.value == 2 ? "FACE" :
        exposure->af_method.value == 1 ? "SINGLE" : exposure->af_method.value == 10 ? "SPOT" : exposure->af_method.value == 4 ? "ZONE" : "OTHER";
    snprintf(s_state.camera_focus_line, sizeof(s_state.camera_focus_line), "AF %s / SERVO %s", af,
        !exposure->movie_servo.known ? "--" : exposure->movie_servo.value ? "ON" : "OFF");
    s_state.revision++;
    xSemaphoreGive(s_lock);
}

void rig_state_get_exposure(eos_exposure_t *exposure)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *exposure = s_exposure;
    xSemaphoreGive(s_lock);
}

void rig_state_set_camera_capabilities(bool set, bool af, bool cancel, bool step)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_state.camera_can_set != set || s_state.camera_can_af != af ||
        s_state.camera_can_cancel_af != cancel || s_state.camera_can_focus_step != step) s_state.revision++;
    s_state.camera_can_set = set;
    s_state.camera_can_af = af;
    s_state.camera_can_cancel_af = cancel;
    s_state.camera_can_focus_step = step;
    xSemaphoreGive(s_lock);
}

void rig_state_set_camera_extra_operations(uint32_t flags)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_state.camera_extra_operations != flags) s_state.revision++;
    s_state.camera_extra_operations = flags;
    xSemaphoreGive(s_lock);
}

void rig_state_set_camera_geometry(uint32_t width, uint32_t height, uint32_t jpeg_width, uint32_t jpeg_height)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_state.camera_af_width != width || s_state.camera_af_height != height ||
        s_state.camera_jpeg_width != jpeg_width || s_state.camera_jpeg_height != jpeg_height) s_state.revision++;
    s_state.camera_af_width = width; s_state.camera_af_height = height;
    s_state.camera_jpeg_width = jpeg_width; s_state.camera_jpeg_height = jpeg_height;
    xSemaphoreGive(s_lock);
}

void rig_state_set_camera_command(const char *id, const char *status, const char *message)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    copy_string(s_state.camera_command_id, sizeof(s_state.camera_command_id), id);
    copy_string(s_state.camera_command_status, sizeof(s_state.camera_command_status), status);
    copy_string(s_state.camera_command_message, sizeof(s_state.camera_command_message), message);
    s_state.revision++;
    xSemaphoreGive(s_lock);
}

void rig_state_set_light(bool ready, uint8_t brightness, uint8_t preset, const char *effect)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    brightness = brightness > 100 ? 100 : brightness;
    if (copy_string(s_state.light_effect, sizeof(s_state.light_effect), effect) ||
        s_state.light_ready != ready || s_state.light_brightness != brightness || s_state.light_preset != preset)
        s_state.revision++;
    s_state.light_ready = ready;
    s_state.light_brightness = brightness;
    s_state.light_preset = preset;
    xSemaphoreGive(s_lock);
}

void rig_state_set_camera_usb(bool connected, uint16_t vendor, uint16_t product, bool ptp_interface, const char *status)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_state.camera_usb_connected = connected;
    s_state.camera_vendor_id = vendor;
    s_state.camera_product_id = product;
    s_state.camera_ptp_interface = ptp_interface;
    s_state.camera_connected = false; // USB enumeration is not an open PTP session.
    s_state.camera_polling_paused = false;
    s_state.camera_generation++;
    s_state.camera_extra_operations = 0;
    s_state.camera_af_width = s_state.camera_af_height = s_state.camera_jpeg_width = s_state.camera_jpeg_height = 0;
    s_state.camera_can_set = s_state.camera_can_af = s_state.camera_can_cancel_af = s_state.camera_can_focus_step = false;
    memset(&s_state.camera_info, 0, sizeof(s_state.camera_info));
    memset(&s_exposure, 0, sizeof(s_exposure));
    s_state.camera_exposure_line[0] = s_state.camera_focus_line[0] = 0;
    copy_string(s_state.camera_status, sizeof(s_state.camera_status), status);
    s_state.revision++;
    xSemaphoreGive(s_lock);
}

void rig_state_set_test(const char *status)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (copy_string(s_state.test_status, sizeof(s_state.test_status), status)) s_state.revision++;
    xSemaphoreGive(s_lock);
}

void rig_state_set_fault(const char *message)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool changed = copy_string(s_state.fault, sizeof(s_state.fault), message);
    if (changed || s_state.mode != RIG_FAULT) s_state.revision++;
    s_state.mode = RIG_FAULT;
    xSemaphoreGive(s_lock);
}

const char *rig_mode_name(rig_mode_t mode)
{
    switch (mode) {
        case RIG_IDLE: return "idle";
        case RIG_PREVIEW: return "preview";
        case RIG_PREPARING: return "preparing";
        case RIG_ON_CALL: return "on_call";
        case RIG_MANUAL: return "manual";
        case RIG_FAULT: return "fault";
        default: return "unknown";
    }
}

bool rig_mode_parse(const char *value, rig_mode_t *mode)
{
    if (!value || !mode) return false;
    const struct { const char *name; rig_mode_t mode; } values[] = {
        {"idle", RIG_IDLE}, {"preview", RIG_PREVIEW},
        {"preparing", RIG_PREPARING}, {"on_call", RIG_ON_CALL},
        {"manual", RIG_MANUAL}, {"fault", RIG_FAULT},
    };
    for (size_t i = 0; i < sizeof(values) / sizeof(values[0]); i++) {
        if (strcmp(value, values[i].name) == 0) {
            *mode = values[i].mode;
            return true;
        }
    }
    return false;
}
