#include "rig_camera.h"

#include <stdio.h>
#include <string.h>
#include "esp_heap_caps.h"
#include "hal/usb_dwc_ll.h"
#include "ptp_codec.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "rig_state.h"
#include "usb/usb_host.h"

static const char *TAG = "rig_camera";
static usb_host_client_handle_t s_client;
static usb_device_handle_t s_device;
// Only the client task and its callback access these fields.
static uint8_t s_pending_address;
static bool s_gone;
static uint8_t s_interface, s_in, s_out;
static uint16_t s_packet;
static bool s_claimed, s_done;
static bool s_claim_retry_pending;
static TickType_t s_last_claim_failure;
#define PTP_CLAIM_RETRY_MS 2000
static usb_transfer_t *s_transfer;
static bool s_eos_polling;
static bool s_evf_hold;
static uint32_t s_evf_hold_original;
static uint32_t s_evf_hold_property;
static uint32_t s_transaction_id;
static TickType_t s_last_poll;
static eos_exposure_t s_exposure;
static uint16_t s_response;
typedef struct {
    char id[65];
    camera_action_t action;
    uint32_t property, value, generation;
} camera_command_t;
static QueueHandle_t s_commands;
static SemaphoreHandle_t s_command_slot;
#define PTP_BUFFER_SIZE 1048576

const char *rig_camera_submit(const char *id, camera_action_t action, uint32_t property, uint32_t value)
{
    if (!id || !*id || strlen(id) > 64) return "camera command requires an id (1-64 chars)";
    rig_snapshot_t state = rig_state_get();
    bool paused_wake = (action == CAMERA_WAKE || action == CAMERA_RECOVER_VIDEO || action == CAMERA_TEST_REMOTE_OFF || action == CAMERA_TEST_REMOTE_ON) && state.camera_polling_paused && state.camera_usb_connected;
    if (!state.camera_connected && !paused_wake) return "camera not ready";
    if (!strcmp(state.camera_command_id, id)) return "duplicate camera command";
    bool supported = action == CAMERA_SET ? state.camera_can_set : action == CAMERA_AF ? state.camera_can_af :
        action == CAMERA_TEST_TERMINATE_LV || action == CAMERA_TEST_EVF_MODE_OFF ? !strcmp(state.camera_info.model, "Canon EOS M6 Mark II") && state.camera_can_set :
        action == CAMERA_TEST_REMOTE_OFF || action == CAMERA_TEST_REMOTE_ON ? !strcmp(state.camera_info.model, "Canon EOS M6 Mark II") :
        action == CAMERA_AF_CANCEL ? state.camera_can_cancel_af : action == CAMERA_FOCUS_STEP ? state.camera_can_focus_step :
        action == CAMERA_PREPARE_AF || action == CAMERA_AF_POINT ? (state.camera_extra_operations & 3) == 3 :
        action == CAMERA_TEST_EVF_OFF || action == CAMERA_RECOVER_VIDEO || action == CAMERA_HOLD_EVF_OFF ? !strcmp(state.camera_info.model, "Canon EOS M6 Mark II") && state.camera_can_set :
        action == CAMERA_PAUSE_POLLING || action == CAMERA_WAKE ?
            !strcmp(state.camera_info.model, "Canon EOS M6 Mark II") && (state.camera_extra_operations & 4) : false;
    if (!supported) return "camera operation not supported";
    if (action == CAMERA_SET && !eos_property(&s_exposure, property)) return "unknown camera property";
    if (action == CAMERA_FOCUS_STEP && !(value >= 1 && value <= 3) && !(value >= 0x8001 && value <= 0x8003))
        return "invalid focus step";
    if (action == CAMERA_AF_POINT && (property > 10000 || value > 10000 || !state.camera_af_width || !state.camera_af_height))
        return "focus geometry not ready or invalid coordinates";
    if (!s_commands || !s_command_slot || xSemaphoreTake(s_command_slot, 0) != pdTRUE) return "camera command busy";
    camera_command_t command = {.action=action, .property=property, .value=value, .generation=state.camera_generation};
    strlcpy(command.id, id, sizeof(command.id));
    rig_state_set_camera_command(id, "queued", "Command queued");
    if (xQueueSend(s_commands, &command, 0) != pdTRUE) {
        xSemaphoreGive(s_command_slot);
        rig_state_set_camera_command(id, "failed", "Command queue unavailable");
        return "camera command queue full";
    }
    return NULL;
}

static void transfer_done(usb_transfer_t *transfer)
{
    (void)transfer;
    s_done = true;
}

static bool exchange_packet(uint8_t endpoint, int length)
{
    s_transfer->device_handle = s_device;
    s_transfer->bEndpointAddress = endpoint;
    s_transfer->num_bytes = length;
    s_transfer->callback = transfer_done;
    s_done = false;
    esp_err_t error = usb_host_transfer_submit(s_transfer);
    if (error != ESP_OK) { s_done = true; return false; }
    TickType_t start = xTaskGetTickCount();
    while (!s_done && !s_gone && xTaskGetTickCount() - start < pdMS_TO_TICKS(3000))
        usb_host_client_handle_events(s_client, pdMS_TO_TICKS(20));
    if (!s_done) {
        ESP_LOGW(TAG, "PTP endpoint %02x timeout/disconnect; canceling", endpoint);
        usb_host_endpoint_halt(s_device, endpoint);
        usb_host_endpoint_flush(s_device, endpoint);
        start = xTaskGetTickCount();
        while (!s_done && xTaskGetTickCount() - start < pdMS_TO_TICKS(1000))
            usb_host_client_handle_events(s_client, pdMS_TO_TICKS(20));
        if (s_done && !s_gone) usb_host_endpoint_clear(s_device, endpoint);
        return false;
    }
    return !s_gone && s_transfer->status == USB_TRANSFER_STATUS_COMPLETED;
}

// A transaction may contain split headers, a DATA container, and a RESPONSE.
// Keep USB transfer storage alive until the completion callback, including errors.
static bool transaction_impl(uint16_t operation, uint32_t id, const uint32_t *parameters,
                        size_t parameter_count, uint8_t *payload, size_t capacity,
                        size_t *payload_size, uint32_t write_property, uint32_t write_value)
{
    s_response = 0;
    *payload_size = 0;
    if (!s_transfer || !s_done || s_gone) return false;
    uint8_t *buffer = heap_caps_malloc(PTP_BUFFER_SIZE, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!buffer) return false;
    size_t length = ptp_encode_command(s_transfer->data_buffer, s_transfer->data_buffer_size,
                                      operation, id, parameters, parameter_count);
    if (!length || !exchange_packet(s_out, length)) { heap_caps_free(buffer); return false; }
    if (write_property) {
        length = eos_encode_property(s_transfer->data_buffer, s_transfer->data_buffer_size, id, write_property, write_value);
        if (!length || !exchange_packet(s_out, length)) { heap_caps_free(buffer); return false; }
    }
    size_t used = 0;
    bool data_seen = false;
    bool success = false;
    TickType_t start = xTaskGetTickCount();
    while (!s_gone && xTaskGetTickCount() - start < pdMS_TO_TICKS(8000)) {
        if (!exchange_packet(s_in, s_packet)) break;
        size_t received = s_transfer->actual_num_bytes;
        if (received > PTP_BUFFER_SIZE - used) break;
        memcpy(buffer + used, s_transfer->data_buffer, received);
        used += received;
        while (used >= 12) {
            uint32_t wanted = (uint32_t)buffer[0] | ((uint32_t)buffer[1] << 8) |
                ((uint32_t)buffer[2] << 16) | ((uint32_t)buffer[3] << 24);
            if (wanted < 12 || wanted > PTP_BUFFER_SIZE) goto finished;
            if (used < wanted) break;
            ptp_container_header_t header;
            if (!ptp_decode_header(buffer, used, &header) || header.transaction_id != id) goto finished;
            if (header.type == PTP_CONTAINER_DATA) {
                if (data_seen || header.code != operation || wanted - 12 > capacity) goto finished;
                memcpy(payload, buffer + 12, wanted - 12);
                *payload_size = wanted - 12;
                data_seen = true;
            } else if (header.type == PTP_CONTAINER_RESPONSE) {
                s_response = header.code;
                if (operation != 0x9116 || header.code != 0x2001 || *payload_size > 8)
                    ESP_LOGI(TAG, "PTP operation=%04x transaction=%lu response=%04x data=%u bytes",
                    operation, (unsigned long)id, header.code, (unsigned)*payload_size);
                success = header.code == 0x2001;
                goto finished;
            } else goto finished;
            used -= wanted;
            memmove(buffer, buffer + wanted, used);
        }
    }
finished:
    heap_caps_free(buffer);
    return success;
}

static bool transaction(uint16_t operation, uint32_t id, const uint32_t *parameters,
                        size_t parameter_count, uint8_t *payload, size_t capacity, size_t *payload_size)
{
    return transaction_impl(operation, id, parameters, parameter_count, payload, capacity, payload_size, 0, 0);
}

static bool poll_eos(uint8_t *payload)
{
    size_t length;
    if (!transaction(0x9116, s_transaction_id++, NULL, 0, payload, PTP_BUFFER_SIZE, &length) ||
        !eos_decode_events(payload, length, &s_exposure)) return false;
    rig_state_set_exposure(&s_exposure);
    bool ready = s_exposure.aperture.known && s_exposure.shutter.known && s_exposure.iso.known;
    rig_state_set_camera(true, ready ? "EOS CONTROL READY" : "EOS waiting values");
    if (length > 8) ESP_LOGI(TAG, "EOS exposure Av=%s%lx Tv=%s%lx ISO=%s%lx options=%lu/%lu/%lu",
        s_exposure.aperture.known ? "" : "?", (unsigned long)s_exposure.aperture.value,
        s_exposure.shutter.known ? "" : "?", (unsigned long)s_exposure.shutter.value,
        s_exposure.iso.known ? "" : "?", (unsigned long)s_exposure.iso.value,
        (unsigned long)s_exposure.aperture.option_count, (unsigned long)s_exposure.shutter.option_count,
        (unsigned long)s_exposure.iso.option_count);
    return true;
}

static void camera_read_fault(void)
{
    s_eos_polling = false;
    memset(&s_exposure, 0, sizeof(s_exposure));
    rig_state_set_exposure(&s_exposure);
    rig_state_set_camera(false, "EOS link error");
}

static void execute_command(const camera_command_t *command)
{
    const char *result = "failed", *message = "Camera session changed";
    char detail[96];
    uint8_t *payload = NULL;
    rig_snapshot_t state = rig_state_get();
    bool paused_wake = (command->action == CAMERA_WAKE || command->action == CAMERA_RECOVER_VIDEO || command->action == CAMERA_TEST_REMOTE_OFF || command->action == CAMERA_TEST_REMOTE_ON) && state.camera_polling_paused;
    if (s_evf_hold && command->action != CAMERA_RECOVER_VIDEO) {
        message = "EVF test held; use camera.recoverVideo"; goto finished;
    }
    if ((!s_eos_polling && !paused_wake) || !s_device || s_gone || command->generation != state.camera_generation) goto finished;
    rig_state_set_camera_command(command->id, "running", "Waiting for camera");
    if (command->action == CAMERA_PAUSE_POLLING) {
        // Bench operation only. Leave the session and power settings untouched.
        // Stopping traffic may allow Canon's own timer to expire, but USB/HDMI
        // can prevent that. Never report this controller state as physical sleep.
        s_eos_polling = false;
        rig_state_set_camera_polling_paused(true);
        rig_state_set_camera(false, "EOS POLLING PAUSED");
        result = "accepted"; message = "USB polling paused; physical sleep is unconfirmed";
        goto finished;
    }
    payload = heap_caps_malloc(PTP_BUFFER_SIZE, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!payload) { message = "Camera command: no memory"; goto finished; }
    if (command->action == CAMERA_TEST_TERMINATE_LV || command->action == CAMERA_TEST_EVF_MODE_OFF) {
        // Explicitly requested experiments, not advertised capabilities or
        // production controls. No automatic retry of unsupported operations.
        bool mode_test = command->action == CAMERA_TEST_EVF_MODE_OFF;
        if (mode_test && (!s_exposure.evf_mode_known || !s_exposure.evf_mode)) {
            message = "Original active EVF mode unknown; no write sent"; goto finished;
        }
        size_t length = 0;
        rig_state_set_camera(true, mode_test ? "TEST EVF MODE OFF" : "TEST TERMINATE LV");
        if (mode_test) {
            // Arm restoration before writing: a lost response is ambiguous.
            s_evf_hold = true;
            s_evf_hold_property = 0xd1b1;
            s_evf_hold_original = s_exposure.evf_mode;
        }
        bool ok = mode_test ? transaction_impl(0x9110, s_transaction_id++, NULL, 0, payload, PTP_BUFFER_SIZE, &length, 0xd1b1, 0)
                            : transaction(0x9152, s_transaction_id++, NULL, 0, payload, PTP_BUFFER_SIZE, &length);
        if (mode_test || ok || !s_response) {
            s_eos_polling = false;
            rig_state_set_camera_polling_paused(true);
            rig_state_set_camera(false, mode_test ? "HOLD EVF MODE OFF" : "HOLD TERMINATE LV");
        }
        if (!s_response || s_gone) {
            camera_read_fault(); message = "Live View test transport failed; manual reconnect may be needed"; goto finished;
        }
        result = ok ? "accepted" : "failed";
        snprintf(detail, sizeof(detail), "%s PTP=0x%04x; no sensor-state claim", mode_test ? "EVFMode=0" : "TerminateViewfinder", s_response);
        message = detail;
        goto finished;
    }
    if (command->action == CAMERA_TEST_REMOTE_OFF || command->action == CAMERA_TEST_REMOTE_ON) {
        // Isolated bench operation: exactly one Canon transaction. Do not poll,
        // change EVF/EventMode or auto-restore before the user observes HDMI.
        uint32_t mode = command->action == CAMERA_TEST_REMOTE_ON ? 1 : 0;
        size_t length = 0;
        s_eos_polling = false;
        rig_state_set_camera_polling_paused(true);
        rig_state_set_camera(false, mode ? "TEST REMOTE ON" : "TEST REMOTE OFF");
        bool accepted = transaction(0x9114, s_transaction_id++, &mode, 1, payload, PTP_BUFFER_SIZE, &length);
        if (!s_response || s_gone) {
            camera_read_fault(); message = "Remote test transport failed; reconnect Canon"; goto finished;
        }
        result = accepted ? "accepted" : "failed";
        snprintf(detail, sizeof(detail), "Only RemoteMode=%lu PTP=0x%04x; polling paused; check HDMI",
            (unsigned long)mode, s_response);
        message = detail;
        goto finished;
    }
    if (command->action == CAMERA_RECOVER_VIDEO) {
        // Bench-only: libgphoto2's EOS unprepare sequence resets remote mode
        // 0 -> 1 and disables events. Re-enable our event mode afterwards.
        // This does not close the PTP session or claim physical wake/HDMI proof.
        size_t length = 0;
        uint32_t disabled = 0, enabled = 1;
        rig_state_set_camera(true, "VIDEO REMOTE RESET");
        if (s_evf_hold) {
            if (!transaction_impl(0x9110, s_transaction_id++, NULL, 0, payload, PTP_BUFFER_SIZE, &length, s_evf_hold_property, s_evf_hold_original)) {
                camera_read_fault(); message = "Held EVF output restore failed; reconnect Canon"; goto finished;
            }
        }
        bool reset_ok = transaction(0x9114, s_transaction_id++, &disabled, 1, payload, PTP_BUFFER_SIZE, &length);
        uint16_t reset_response = s_response;
        if (!s_response || s_gone) { camera_read_fault(); message = "Remote reset transport failed; reconnect Canon"; goto finished; }
        bool enable_ok = transaction(0x9114, s_transaction_id++, &enabled, 1, payload, PTP_BUFFER_SIZE, &length);
        if (!s_response || s_gone) { camera_read_fault(); message = "Remote enable transport failed; reconnect Canon"; goto finished; }
        bool events_off = transaction(0x9115, s_transaction_id++, &disabled, 1, payload, PTP_BUFFER_SIZE, &length);
        if (!s_response || s_gone) { camera_read_fault(); message = "Event reset transport failed; reconnect Canon"; goto finished; }
        bool events_on = transaction(0x9115, s_transaction_id++, &enabled, 1, payload, PTP_BUFFER_SIZE, &length);
        if (!events_on) { camera_read_fault(); message = "Could not restore EOS events; reconnect Canon"; goto finished; }
        memset(&s_exposure, 0, sizeof(s_exposure));
        rig_state_set_exposure(&s_exposure);
        if (!poll_eos(payload)) { camera_read_fault(); message = "Remote reset readback failed; reconnect Canon"; goto finished; }
        s_evf_hold = false;
        s_eos_polling = true;
        rig_state_set_camera_polling_paused(false);
        s_last_poll = xTaskGetTickCount();
        result = reset_ok && enable_ok && events_off ? "accepted" : "failed";
        snprintf(detail, sizeof(detail), "Remote reset=0x%04x enable=%u events=%u; verify live HDMI image", reset_response, enable_ok, events_off && events_on);
        message = detail;
        goto finished;
    }
    if (command->action == CAMERA_WAKE) {
        size_t length = 0;
        rig_state_set_camera(false, "EOS WAKE CHECK");
        rig_state_set_camera_polling_paused(false);
        if (!transaction(0x911d, s_transaction_id++, NULL, 0, payload, PTP_BUFFER_SIZE, &length)) {
            snprintf(detail, sizeof(detail), "KeepDeviceOn failed: PTP 0x%04x; manual wake may be required", s_response);
            message = detail; camera_read_fault(); goto finished;
        }
        if (!poll_eos(payload)) {
            camera_read_fault(); message = "KeepDeviceOn accepted but PTP readback failed"; goto finished;
        }
        s_eos_polling = true;
        s_last_poll = xTaskGetTickCount();
        result = "confirmed"; message = "PTP control restored; physical wake/HDMI needs verification";
        goto finished;
    }
    rig_state_set_camera(true, command->action == CAMERA_SET ? "EOS SET PARAMETER" : "EOS FOCUS COMMAND");
    if (!poll_eos(payload)) { camera_read_fault(); message = "Camera read failed before command"; goto finished; }
    eos_property_t *property = command->action == CAMERA_SET ? eos_property(&s_exposure, command->property) : NULL;
    if (command->action == CAMERA_SET && !eos_property_allows(property, command->value)) {
        message = "Value is not in the camera's current options"; goto finished;
    }
    size_t length;
    bool ok;
    if (command->action == CAMERA_TEST_EVF_OFF || command->action == CAMERA_HOLD_EVF_OFF) {
        // Explicit bench test, never called by presence automation. libgphoto2's
        // EOS viewfinder-off fallback is EVFOutputDevice=0. This controls output,
        // not a documented sensor power state. Always restore on this task,
        // even when the requesting computer disconnects.
        if (!s_exposure.evf_output_known || !s_exposure.evf_output) {
            message = "Original active EVF output unknown; no changes made"; goto finished;
        }
        uint32_t original = s_exposure.evf_output;
        rig_state_set_camera(true, "TEST EVF OFF 5s");
        ok = transaction_impl(0x9110, s_transaction_id++, NULL, 0, payload, PTP_BUFFER_SIZE, &length, 0xd1b0, 0);
        uint16_t off_response = s_response;
        bool off_seen = false;
        if (command->action == CAMERA_HOLD_EVF_OFF && ok) {
            // User-observed, two-step bench test. No automatic restore or polls
            // until an explicit recoverVideo (or physical USB reconnect).
            s_evf_hold_original = original;
            s_evf_hold_property = 0xd1b0;
            s_evf_hold = true;
            s_eos_polling = false;
            rig_state_set_camera_polling_paused(true);
            rig_state_set_camera(false, "EVF HOLD: CHECK HDMI");
            result = "accepted"; message = "EVF off accepted; waiting for visual check, not proof of sleep";
            goto finished;
        }
        if (ok) {
            for (int i = 0; i < 4; i++) {
                if (!poll_eos(payload)) break;
                if (s_exposure.evf_output_known && s_exposure.evf_output == 0) { off_seen = true; break; }
                usb_host_client_handle_events(s_client, pdMS_TO_TICKS(100));
            }
            rig_state_set_camera(true, "TEST EVF OFF 5s");
            TickType_t start = xTaskGetTickCount();
            while (!s_gone && xTaskGetTickCount() - start < pdMS_TO_TICKS(5000))
                usb_host_client_handle_events(s_client, pdMS_TO_TICKS(100));
        }
        // Restore even after a rejection/timeout: a lost response is ambiguous.
        rig_state_set_camera(true, "TEST EVF RESTORE");
        if (s_gone || !transaction_impl(0x9110, s_transaction_id++, NULL, 0, payload, PTP_BUFFER_SIZE, &length, 0xd1b0, original)) {
            message = "EVF restore failed; manually restart/reconnect Canon";
            camera_read_fault(); goto finished;
        }
        bool restored = false;
        for (int i = 0; i < 4; i++) {
            if (!poll_eos(payload)) break;
            if (s_exposure.evf_output_known && s_exposure.evf_output == original) { restored = true; break; }
            usb_host_client_handle_events(s_client, pdMS_TO_TICKS(100));
        }
        if (!restored) { camera_read_fault(); message = "EVF restore readback unconfirmed; check Canon"; goto finished; }
        snprintf(detail, sizeof(detail), "EVF off PTP=0x%04x readback=%s; restored=%lu; sensor power unverified",
            off_response, off_seen ? "0" : "unconfirmed", (unsigned long)original);
        result = ok && off_seen ? "confirmed" : "failed";
        message = detail;
        goto finished;
    }
    if (command->action == CAMERA_PREPARE_AF) {
        rig_state_set_camera_geometry(0, 0, 0, 0);
        if (!s_exposure.evf_output_known) { message = "Unknown EVF output; not changing it"; goto finished; }
        uint32_t args[] = {0x00200000, 0, 0}, w = 0, h = 0, jw = 0, jh = 0;
        if (state.camera_extra_operations & 16) {
            uint32_t property_code = 0xd1d3;
            transaction(0x9127, s_transaction_id++, &property_code, 1, payload, PTP_BUFFER_SIZE, &length);
            if (!s_response || !poll_eos(payload)) { camera_read_fault(); message = "AF information request failed"; goto finished; }
        }
        if (transaction(0x9153, s_transaction_id++, args, 3, payload, PTP_BUFFER_SIZE, &length) &&
            eos_decode_live_geometry(payload, length, &w, &h, &jw, &jh)) {
            rig_state_set_camera_geometry(w, h, jw, jh);
            result = "confirmed"; message = "AF geometry read without changing EVF output"; goto finished;
        }
        if (!s_response) { camera_read_fault(); message = "Live View transport failed"; goto finished; }
        uint32_t original = s_exposure.evf_output;
        bool changed = !(original & 2);
        if (changed && !transaction_impl(0x9110, s_transaction_id++, NULL, 0, payload, PTP_BUFFER_SIZE, &length, 0xd1b0, original | 2)) {
            if (s_response != 0x2019 || !transaction_impl(0x9110, s_transaction_id++, NULL, 0, payload, PTP_BUFFER_SIZE, &length, 0xd1b0, 2)) {
                snprintf(detail, sizeof(detail), "Cannot enable host Live View: PTP 0x%04x", s_response);
                message = detail; if (!s_response) camera_read_fault(); goto finished;
            }
        }
        bool geometry = false;
        for (int attempt = 0; attempt < 3; attempt++) {
            if (transaction(0x9153, s_transaction_id++, args, 3, payload, PTP_BUFFER_SIZE, &length)) {
                geometry = eos_decode_live_geometry(payload, length, &w, &h, &jw, &jh);
                break;
            }
            if (s_response != 0xa102) break;
            usb_host_client_handle_events(s_client, pdMS_TO_TICKS(250));
        }
        if (!s_response) {
            camera_read_fault(); message = "Live View transfer failed; output restoration needs reconnect"; goto finished;
        }
        if (changed && !transaction_impl(0x9110, s_transaction_id++, NULL, 0, payload, PTP_BUFFER_SIZE, &length, 0xd1b0, original)) {
            message = "Could not restore original EVF output"; camera_read_fault(); goto finished;
        }
        if (!poll_eos(payload)) { camera_read_fault(); message = "Live View readback failed"; goto finished; }
        if (changed && (!s_exposure.evf_output_known || s_exposure.evf_output != original)) {
            message = "EVF output restoration not confirmed"; goto finished;
        }
        if (!geometry) { message = "Camera returned no usable focus geometry"; goto finished; }
        rig_state_set_camera_geometry(w, h, jw, jh);
        snprintf(detail, sizeof(detail), "AF geometry %lux%lu, preview %lux%lu; EVF output restored",
            (unsigned long)w, (unsigned long)h, (unsigned long)jw, (unsigned long)jh);
        result = "confirmed"; message = detail; goto finished;
    }
    if (command->action == CAMERA_SET) {
        ok = transaction_impl(0x9110, s_transaction_id++, NULL, 0, payload, PTP_BUFFER_SIZE, &length,
                              command->property, command->value);
    } else if (command->action == CAMERA_AF_POINT) {
        uint32_t args[] = {3, (uint32_t)((uint64_t)command->property * (state.camera_af_width - 1) / 10000),
                              (uint32_t)((uint64_t)command->value * (state.camera_af_height - 1) / 10000)};
        ok = transaction(0x915b, s_transaction_id++, args, 3, payload, PTP_BUFFER_SIZE, &length);
    } else {
        uint16_t operation = command->action == CAMERA_AF ? 0x9154 : command->action == CAMERA_AF_CANCEL ? 0x9160 : 0x9155;
        ok = transaction(operation, s_transaction_id++, &command->value,
                         command->action == CAMERA_FOCUS_STEP ? 1 : 0, payload, PTP_BUFFER_SIZE, &length);
    }
    if (!ok) {
        if (!s_response) { camera_read_fault(); message = "USB/PTP failure; reconnect camera before retry"; }
        else {
            snprintf(detail, sizeof(detail), "Canon rejected command: PTP 0x%04x", s_response);
            message = detail;
        }
        goto finished;
    }
    // Never optimistically overwrite the camera cache. Confirm property writes
    // from subsequent events; AF acceptance does not mean focus was achieved.
    for (int attempt = 0; attempt < 4; attempt++) {
        if (!poll_eos(payload)) { camera_read_fault(); message = "Command accepted; readback failed"; goto finished; }
        if (command->action != CAMERA_SET) {
            result = "accepted"; message = "Focus command accepted (not a focus-lock confirmation)"; goto finished;
        }
        if (property->known && property->value == command->value) {
            result = "confirmed"; message = "Value confirmed by camera"; goto finished;
        }
        usb_host_client_handle_events(s_client, pdMS_TO_TICKS(150));
        if (s_gone) break;
    }
    result = "unconfirmed"; message = "Command accepted but value was not confirmed";
finished:
    heap_caps_free(payload);
    rig_state_set_camera_command(command->id, result, message);
    ESP_LOGI(TAG, "Camera command %s: %s", result, message);
    xSemaphoreGive(s_command_slot);
}

static void probe_ptp(void)
{
    rig_state_set_camera(false, "PTP reading info");
    if (usb_host_transfer_alloc(s_packet, 0, &s_transfer) != ESP_OK) {
        rig_state_set_camera(false, "PTP no memory");
        return;
    }
    s_done = true;
    uint8_t *payload = heap_caps_malloc(PTP_BUFFER_SIZE, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    size_t length = 0;
    ptp_device_info_t info;
    bool ok = payload && transaction(0x1001, 0, NULL, 0, payload, 16384, &length) &&
        ptp_decode_device_info(payload, length, &info);
    bool eos_supported = ok && ptp_device_supports_operation(payload, length, 0x9114) &&
        ptp_device_supports_operation(payload, length, 0x9115) &&
        ptp_device_supports_operation(payload, length, 0x9116);
    if (ok) {
        uint32_t flags = 0;
        const uint16_t operations[] = {0x915b, 0x9153, 0x911d, 0x1013, 0x9127, 0x9151, 0x9152};
        for (unsigned i = 0; i < sizeof(operations) / sizeof(operations[0]); i++) if (ptp_device_supports_operation(payload, length, operations[i])) flags |= 1U << i;
        rig_state_set_camera_extra_operations(flags);
    }
    if (ok) rig_state_set_camera_capabilities(
        ptp_device_supports_operation(payload, length, 0x9110),
        ptp_device_supports_operation(payload, length, 0x9154),
        ptp_device_supports_operation(payload, length, 0x9160),
        ptp_device_supports_operation(payload, length, 0x9155));
    if (ok) {
        rig_state_set_camera_info(&info);
        ESP_LOGI(TAG, "PTP CAMERA: %s / %s / firmware %s; operations=%lu events=%lu properties=%lu",
            info.manufacturer, info.model, info.version, (unsigned long)info.operation_count,
            (unsigned long)info.event_count, (unsigned long)info.property_count);
        uint32_t session = 1;
        rig_state_set_camera(false, "PTP opening session");
        ok = transaction(0x1002, 0, &session, 1, payload, 16384, &length);
    }
    rig_state_set_camera(ok, ok ? "CANON PTP READY" : "PTP probe failed");
    ESP_LOGI(TAG, "PTP probe %s; no exposure/focus settings changed", ok ? "READY" : "FAILED");
    s_transaction_id = 1;
    memset(&s_exposure, 0, sizeof(s_exposure));
    s_eos_polling = false;
    // Initialization only enables events. Camera settings/focus are changed
    // solely by explicit queued commands; no capture, UI-lock or EVF commands.
    if (ok && eos_supported && strcmp(info.model, "Canon EOS M6 Mark II") == 0) {
        rig_state_set_camera(true, "EOS enabling events");
        uint32_t enabled = 1;
        s_eos_polling = transaction(0x9114, s_transaction_id++, &enabled, 1, payload, PTP_BUFFER_SIZE, &length) &&
            transaction(0x9115, s_transaction_id++, &enabled, 1, payload, PTP_BUFFER_SIZE, &length) && poll_eos(payload);
        if (!s_eos_polling) rig_state_set_camera(false, "EOS read failed");
        s_last_poll = xTaskGetTickCount();
    }
    heap_caps_free(payload);
}

static void claim_and_probe_ptp(void)
{
    esp_err_t error = usb_host_interface_claim(s_client, s_device, s_interface, 0);
    if (error != ESP_OK) {
        s_last_claim_failure = xTaskGetTickCount();
        s_claim_retry_pending = true;
        char status[24];
        snprintf(status, sizeof(status), "PTP retry 0x%04X", (unsigned)error);
        rig_state_set_camera(false, status);
        ESP_LOGW(TAG, "Interface %u claim: %s; retry in %d ms",
                 s_interface, esp_err_to_name(error), PTP_CLAIM_RETRY_MS);
        return;
    }
    s_claim_retry_pending = false;
    s_claimed = true;
    probe_ptp();
}

static void client_event(const usb_host_client_event_msg_t *event, void *argument)
{
    (void)argument;
    if (event->event == USB_HOST_CLIENT_EVENT_NEW_DEV) {
        s_pending_address = event->new_dev.address;
    } else if (event->event == USB_HOST_CLIENT_EVENT_DEV_GONE && event->dev_gone.dev_hdl == s_device) {
        s_claim_retry_pending = false;
        s_gone = true;
    } else if (event->event == USB_HOST_CLIENT_EVENT_DEV_REMOVED && event->dev_removed.address == s_pending_address) {
        s_pending_address = 0;
    }
}

static bool inspect_configuration(const usb_config_desc_t *config)
{
    const uint8_t *bytes = (const uint8_t *)config;
    size_t total = config->wTotalLength;
    if (total < 9 || total > 4096) return false;
    bool candidate = false, bulk_in = false, bulk_out = false, found = false;
    for (size_t offset = 0; offset + 2 <= total;) {
        uint8_t length = bytes[offset], type = bytes[offset + 1];
        if (length < 2 || offset + length > total) {
            ESP_LOGW(TAG, "Malformed USB configuration at offset %u", (unsigned)offset);
            return false;
        }
        if (type == 4 && length >= 9) {
            found |= candidate && bulk_in && bulk_out;
            if (found) return true;
            bulk_in = bulk_out = false;
            candidate = bytes[offset+3] == 0 && bytes[offset+5] == 6 && bytes[offset+6] == 1 && bytes[offset+7] == 1;
            if (candidate) s_interface = bytes[offset+2];
            ESP_LOGI(TAG, "INTERFACE %u alt=%u class=%02x subclass=%02x protocol=%02x endpoints=%u",
                bytes[offset+2], bytes[offset+3], bytes[offset+5], bytes[offset+6], bytes[offset+7], bytes[offset+4]);
        } else if (type == 5 && length >= 7) {
            uint8_t address = bytes[offset+2], attributes = bytes[offset+3] & 3;
            unsigned packet = bytes[offset+4] | (bytes[offset+5] << 8);
            ESP_LOGI(TAG, "ENDPOINT %02x type=%u max_packet=%u", address, attributes, packet);
            if (candidate && attributes == 2) {
                if (address & 0x80) { bulk_in = true; s_in = address; s_packet = packet; }
                else { bulk_out = true; s_out = address; }
            }
        }
        offset += length;
    }
    return found || (candidate && bulk_in && bulk_out);
}

static void inspect_device(uint8_t address)
{
    if (s_device) {
        ESP_LOGW(TAG, "Additional device %u ignored; one camera supported", address);
        return;
    }
    esp_err_t error = usb_host_device_open(s_client, address, &s_device);
    if (error != ESP_OK) {
        ESP_LOGW(TAG, "Device %u open failed: %s", address, esp_err_to_name(error));
        rig_state_set_camera_usb(false, 0, 0, false, "USB open failed");
        return;
    }
    const usb_device_desc_t *device = NULL;
    const usb_config_desc_t *config = NULL;
    error = usb_host_get_device_descriptor(s_device, &device);
    if (error == ESP_OK) error = usb_host_get_active_config_descriptor(s_device, &config);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "Descriptor read failed: %s", esp_err_to_name(error));
        usb_host_device_close(s_client, s_device);
        s_device = NULL;
        rig_state_set_camera_usb(false, 0, 0, false, "USB descriptor error");
        return;
    }
    ESP_LOGI(TAG, "USB DEVICE address=%u VID=%04x PID=%04x bcdUSB=%04x class=%02x configurations=%u",
             address, device->idVendor, device->idProduct, device->bcdUSB, device->bDeviceClass, device->bNumConfigurations);
    bool ptp_interface = inspect_configuration(config);
    char status[24];
    snprintf(status, sizeof(status), "%s USB %s", device->idVendor == 0x04a9 ? "CANON" : "OTHER", ptp_interface ? "PTP IF" : "NO PTP IF");
    rig_state_set_camera_usb(true, device->idVendor, device->idProduct, ptp_interface, status);
    if (device->idVendor == 0x04a9 && ptp_interface && s_packet >= 16 && s_packet <= 512) claim_and_probe_ptp();
}

static void usb_client_task(void *argument)
{
    (void)argument;
    TickType_t last_scan = xTaskGetTickCount();
    while (true) {
        esp_err_t error = usb_host_client_handle_events(s_client, pdMS_TO_TICKS(250));
        if (error != ESP_OK && error != ESP_ERR_TIMEOUT) ESP_LOGW(TAG, "USB client: %s", esp_err_to_name(error));
        if (s_gone) {
            s_evf_hold = false;
            s_eos_polling = false;
            // A canceled DMA transfer must finish before its buffer or interface is released.
            if (s_transfer && !s_done) continue;
            if (s_transfer) {
                if (usb_host_transfer_free(s_transfer) != ESP_OK) continue;
                s_transfer = NULL;
            }
            if (s_claimed) {
                error = usb_host_interface_release(s_client, s_device, s_interface);
                if (error != ESP_OK) { ESP_LOGW(TAG, "USB release: %s", esp_err_to_name(error)); continue; }
                s_claimed = false;
            }
            error = usb_host_device_close(s_client, s_device);
            if (error != ESP_OK) { ESP_LOGW(TAG, "USB close: %s", esp_err_to_name(error)); continue; }
            s_device = NULL;
            s_gone = false;
            rig_state_set_camera_usb(false, 0, 0, false, "USB disconnected");
        }
        if (!s_device && !s_pending_address && xTaskGetTickCount() - last_scan >= pdMS_TO_TICKS(2000)) {
            last_scan = xTaskGetTickCount();
            uint8_t address;
            int count = 0;
            if (usb_host_device_addr_list_fill(1, &address, &count) == ESP_OK && count == 1)
                s_pending_address = address;
        }
        if (s_pending_address) {
            uint8_t address = s_pending_address;
            s_pending_address = 0;
            inspect_device(address);
        }
        if (s_claim_retry_pending && !s_gone && s_device &&
            xTaskGetTickCount() - s_last_claim_failure >= pdMS_TO_TICKS(PTP_CLAIM_RETRY_MS)) {
            claim_and_probe_ptp();
        }
        camera_command_t command;
        if (xQueueReceive(s_commands, &command, 0) == pdTRUE) execute_command(&command);
        if (s_eos_polling && xTaskGetTickCount() - s_last_poll >= pdMS_TO_TICKS(1000)) {
            uint8_t *payload = heap_caps_malloc(PTP_BUFFER_SIZE, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
            if (!payload || !poll_eos(payload)) {
                s_eos_polling = false;
                memset(&s_exposure, 0, sizeof(s_exposure));
                rig_state_set_exposure(&s_exposure);
                rig_state_set_camera(false, "EOS read failed");
            }
            heap_caps_free(payload);
            s_last_poll = xTaskGetTickCount();
        }
    }
}

static void usb_library_task(void *argument)
{
    (void)argument;
    const usb_host_config_t config = {
        .skip_phy_setup = false,
        .intr_flags = ESP_INTR_FLAG_LEVEL1,
    };
    esp_err_t error = usb_host_install(&config);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "USB host install failed: %s", esp_err_to_name(error));
        rig_state_set_camera(false, "USB host fault");
        vTaskDelete(NULL);
        return;
    }

    const usb_host_client_config_t client_config = {
        .is_synchronous=false, .max_num_event_msg=8, .flags.notify_dev_removed=1,
        .async = {.client_event_callback=client_event, .callback_arg=NULL},
    };
    error = usb_host_client_register(&client_config, &s_client);
    if (error != ESP_OK) {
        rig_state_set_camera(false, "USB client error");
        usb_host_uninstall();
        vTaskDelete(NULL);
        return;
    }
    rig_state_set_camera_usb(false, 0, 0, false, "USB waiting Canon");
    if (xTaskCreate(usb_client_task, "usb_camera", 12288, NULL, 6, NULL) != pdPASS) {
        usb_host_client_deregister(s_client);
        usb_host_uninstall();
        rig_state_set_camera(false, "USB task memory");
        vTaskDelete(NULL);
        return;
    }
    ESP_LOGI(TAG, "USB host/client ready: D- GPIO19, D+ GPIO20; EOS control queue enabled");
    TickType_t last_check = xTaskGetTickCount();
    unsigned stalled_seconds = 0;
    bool port_off = false;
    while (true) {
        uint32_t event_flags = 0;
        error = usb_host_lib_handle_events(pdMS_TO_TICKS(1000), &event_flags);
        if (error != ESP_OK && error != ESP_ERR_TIMEOUT) {
            ESP_LOGW(TAG, "USB host event error: %s", esp_err_to_name(error));
        }
        TickType_t now = xTaskGetTickCount();
        if (now - last_check < pdMS_TO_TICKS(1000)) continue;
        last_check = now;
        if (port_off) {
            error = usb_host_lib_set_root_port_power(true);
            port_off = error != ESP_OK;
            if (port_off) ESP_LOGW(TAG, "USB port restart: %s", esp_err_to_name(error));
            continue;
        }
        // Read the S2's physical attach bit independently of completed enumeration.
        // Run port management in the library task, serialized with hub events.
        bool attached = usb_dwc_ll_hprt_get_conn_status(USB_DWC_LL_GET_HW(0));
        rig_state_set_camera_usb_line(attached);
        usb_host_lib_info_t info;
        if (usb_host_lib_info(&info) != ESP_OK || info.num_devices || info.root_port_suspended) {
            stalled_seconds = 0;
            continue;
        }
        // A missed attach can leave even the hardware connect indication clear.
        // Give an idle port a slower retry; never cycle a port with a device object.
        if (++stalled_seconds >= (attached ? 10U : 30U)) {
            stalled_seconds = 0;
            error = usb_host_lib_set_root_port_power(false);
            port_off = error == ESP_OK;
            if (port_off) rig_state_count_camera_port_restart();
            ESP_LOGI(TAG, "USB port recovery, line=%u: %s", attached, esp_err_to_name(error));
        }
    }
}

void rig_camera_init(void)
{
    s_commands = xQueueCreate(1, sizeof(camera_command_t));
    s_command_slot = xSemaphoreCreateBinary();
    if (!s_commands || !s_command_slot) { rig_state_set_camera(false, "USB queue memory"); return; }
    xSemaphoreGive(s_command_slot);
    if (xTaskCreatePinnedToCore(usb_library_task, "usb_host", 4096, NULL, 8, NULL, 0) != pdPASS)
        rig_state_set_camera(false, "USB host memory");
}
