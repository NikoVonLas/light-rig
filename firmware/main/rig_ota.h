#pragma once
#include "cJSON.h"
#include "esp_http_server.h"

// Call begin/write/finish, wire and expire with the network command mutex held.
const char *rig_ota_begin(size_t size, const char *session, const char *target);
const char *rig_ota_write(const void *data, size_t size);
const char *rig_ota_finish(void);
void rig_ota_abort(void);
void rig_ota_expire(void);
int rig_ota_progress(void); // -1 idle, 0..99 writing, 100 verified and restarting
const char *rig_ota_wire(cJSON *payload, bool *restart);
