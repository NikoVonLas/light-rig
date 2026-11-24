#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "ptp_codec.h"
#include "eos_codec.h"

typedef enum {
    RIG_IDLE = 0,
    RIG_PREVIEW,
    RIG_PREPARING,
    RIG_ON_CALL,
    RIG_MANUAL,
    RIG_FAULT,
} rig_mode_t;

typedef struct {
    rig_mode_t mode;
    bool wifi_connected;
    bool camera_connected;
    bool camera_polling_paused; // Host activity paused; NOT confirmation of physical sleep.
    bool camera_usb_connected;
    bool camera_usb_line_attached;
    bool camera_ptp_interface;
    uint16_t camera_vendor_id;
    uint16_t camera_product_id;
    ptp_device_info_t camera_info;
    char camera_exposure_line[40], camera_focus_line[40];
    uint32_t camera_generation;
    uint32_t camera_port_restarts;
    uint32_t camera_extra_operations;
    uint32_t camera_af_width, camera_af_height, camera_jpeg_width, camera_jpeg_height;
    bool camera_can_set, camera_can_af, camera_can_cancel_af, camera_can_focus_step;
    char camera_command_id[65], camera_command_status[24], camera_command_message[96];
    bool light_ready;
    uint8_t light_brightness;
    uint8_t light_preset;
    char light_effect[16];
    char ip_address[16];
    char camera_status[24];
    char test_status[24];
    char fault[64];
    uint32_t revision;
} rig_snapshot_t;

void rig_state_init(void);
rig_snapshot_t rig_state_get(void);
void rig_state_note_activity(void);
void rig_state_set_mode(rig_mode_t mode);
void rig_state_set_wifi(bool connected, const char *ip_address);
void rig_state_set_camera(bool connected, const char *status);
void rig_state_set_camera_usb_line(bool attached);
void rig_state_count_camera_port_restart(void);
void rig_state_set_camera_polling_paused(bool paused);
void rig_state_set_camera_info(const ptp_device_info_t *info);
void rig_state_set_exposure(const eos_exposure_t *exposure);
void rig_state_get_exposure(eos_exposure_t *exposure);
void rig_state_set_camera_capabilities(bool set, bool af, bool cancel, bool step);
void rig_state_set_camera_extra_operations(uint32_t flags);
void rig_state_set_camera_geometry(uint32_t width, uint32_t height, uint32_t jpeg_width, uint32_t jpeg_height);
void rig_state_set_camera_command(const char *id, const char *status, const char *message);
void rig_state_set_camera_usb(bool connected, uint16_t vendor, uint16_t product, bool ptp_interface, const char *status);
void rig_state_set_light(bool ready, uint8_t brightness, uint8_t preset, const char *effect);
void rig_state_set_test(const char *status);
void rig_state_set_fault(const char *message);
const char *rig_mode_name(rig_mode_t mode);
bool rig_mode_parse(const char *value, rig_mode_t *mode);
