#include "presence_model.h"
#include <string.h>
#include <stdio.h>

static bool identifier(const char *s) {
    if (!s || !*s || strlen(s) > 36) return false;
    for (; *s; s++) if (!((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') ||
        (*s >= '0' && *s <= '9') || *s == '-' || *s == '_')) return false;
    return true;
}
bool presence_fresh(const presence_client_t *c, int64_t now) {
    return c->received && now >= c->received_ms && now - c->received_ms < PRESENCE_TTL_MS;
}
const char *presence_update(presence_model_t *m, const char *id, const char *name,
    const char *session, uint32_t sequence, bool call, int camera, bool automatic,
    bool preview, int64_t now) {
    if (!m || !identifier(id) || !identifier(session) || !name || !*name || strlen(name) > 48 ||
        camera < -1 || camera > 1 || (!call && camera == 1)) return "invalid presence";
    for (const unsigned char *p = (const unsigned char *)name; *p; p++)
        if (*p < 32 || *p == 127) return "invalid client name";
    presence_client_t *c = NULL;
    for (int i = 0; i < PRESENCE_CLIENTS; i++) if (!strcmp(m->clients[i].id, id)) c = &m->clients[i];
    if (!c) for (int i = 0; i < PRESENCE_CLIENTS; i++) if (!m->clients[i].id[0]) { c = &m->clients[i]; break; }
    if (!c) return "two clients already registered";
    if (c->received && !strcmp(c->session, session) && sequence <= c->sequence) return "stale presence sequence";
    if (c->received && strcmp(c->session, session) && presence_fresh(c, now)) return "client session still active";
    snprintf(c->id, sizeof(c->id), "%s", id); snprintf(c->name, sizeof(c->name), "%s", name);
    snprintf(c->session, sizeof(c->session), "%s", session);
    c->sequence = sequence; c->received_ms = now; c->received = true;
    c->on_call = call; c->camera = call ? camera : 0; c->automatic = automatic; c->preview = preview;
    return NULL;
}
presence_summary_t presence_summary(const presence_model_t *m, int64_t now) {
    presence_summary_t r = {.call = 0, .camera = 0};
    bool unknown_call = false, unknown_camera = false;
    for (int i = 0; i < PRESENCE_CLIENTS; i++) {
        const presence_client_t *c = &m->clients[i];
        if (!c->id[0]) continue;
        if (!presence_fresh(c, now)) { unknown_call = unknown_camera = true; continue; }
        r.available = true; r.preview |= c->preview; r.automate |= c->on_call && c->automatic;
        if (c->on_call) r.call = 1;
        if (c->camera == 1) r.camera = 1;
        if (c->camera == -1) unknown_camera = true;
    }
    if (!r.available || (r.call != 1 && unknown_call)) r.call = -1;
    if (!r.available || (r.camera != 1 && unknown_camera)) r.camera = -1;
    return r;
}
