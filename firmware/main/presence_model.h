#pragma once
#include <stdbool.h>
#include <stdint.h>

#define PRESENCE_CLIENTS 2
#define PRESENCE_TTL_MS 8000
typedef struct {
    char id[37], name[49], session[37];
    uint32_t sequence;
    int64_t received_ms;
    bool received, on_call, automatic, preview;
    int camera; // -1 unknown, 0 off, 1 on in the call (not local preview).
} presence_client_t;
typedef struct { presence_client_t clients[PRESENCE_CLIENTS]; } presence_model_t;
typedef struct { bool available, automate, preview; int call, camera; } presence_summary_t;
bool presence_fresh(const presence_client_t *client, int64_t now);
const char *presence_update(presence_model_t *model, const char *id, const char *name,
    const char *session, uint32_t sequence, bool call, int camera, bool automatic,
    bool preview, int64_t now);
presence_summary_t presence_summary(const presence_model_t *model, int64_t now);
