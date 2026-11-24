#pragma once
#include "cJSON.h"
void rig_homeassistant_init(void);
const char *rig_homeassistant_configure(cJSON *payload, bool usb);
void rig_homeassistant_json(cJSON *parent);
void rig_homeassistant_usb_settings(cJSON *parent);
