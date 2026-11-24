#pragma once
#include <stdint.h>

typedef enum { CAMERA_SET, CAMERA_AF, CAMERA_AF_CANCEL, CAMERA_FOCUS_STEP, CAMERA_PREPARE_AF, CAMERA_AF_POINT,
    CAMERA_PAUSE_POLLING, CAMERA_WAKE, CAMERA_TEST_EVF_OFF, CAMERA_RECOVER_VIDEO, CAMERA_HOLD_EVF_OFF,
    CAMERA_TEST_REMOTE_OFF, CAMERA_TEST_REMOTE_ON, CAMERA_TEST_TERMINATE_LV, CAMERA_TEST_EVF_MODE_OFF } camera_action_t;
const char *rig_camera_submit(const char *id, camera_action_t action, uint32_t property, uint32_t value);

void rig_camera_init(void);
