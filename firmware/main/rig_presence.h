#pragma once
#include "cJSON.h"
#include "presence_model.h"
void rig_presence_init(void);
const char *rig_presence_receive(cJSON *payload);
presence_model_t rig_presence_get(void);
void rig_presence_json(cJSON *parent);
