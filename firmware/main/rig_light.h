#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    LIGHT_WHITE_WARM,
    LIGHT_WHITE_NEUTRAL,
    LIGHT_WHITE_COOL,
    LIGHT_RGB,
} light_mode_t;

typedef enum {
    LIGHT_EFFECT_SOLID,
    LIGHT_EFFECT_BREATHE,
    LIGHT_EFFECT_RAINBOW,
    LIGHT_EFFECT_COLOR_CYCLE,
} light_effect_t;

typedef struct {
    bool enabled;
    light_mode_t mode;
    uint8_t brightness;
    uint8_t red;
    uint8_t green;
    uint8_t blue;
    uint8_t warm;
    uint8_t cool;
    uint8_t speed;
    light_effect_t effect;
} light_command_t;

typedef struct {
    uint8_t red;
    uint8_t green;
    uint8_t blue;
    uint8_t warm;
    uint8_t cool;
} light_frame_t;

typedef struct {
    int gpio;
    bool valid;
    bool pull_up;
    bool pull_down;
    uint32_t tx_frames;
    light_frame_t last_tx;
} light_output_status_t;

#define LIGHT_CALL_PRESET 3

void rig_light_init(void);
light_command_t rig_light_get_call_preset(void);
bool rig_light_apply(const light_command_t *command);
bool rig_light_apply_preset(uint8_t slot);
bool rig_light_save_preset(uint8_t slot, const char *name, const light_command_t *command);
light_command_t rig_light_get_command(void);
light_frame_t rig_light_get_frame(void);
light_output_status_t rig_light_get_output_status(void);
bool rig_light_is_ready(void);
bool rig_light_run_rgb_test(void);
const char *rig_light_effect_name(light_effect_t effect);
bool rig_light_effect_parse(const char *value, light_effect_t *effect);
