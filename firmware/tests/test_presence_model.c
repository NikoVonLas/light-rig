#include "presence_model.h"
#include <assert.h>
#include <string.h>
int main(void) {
    presence_model_t m = {0};
    presence_summary_t s = presence_summary(&m, 0);
    assert(!s.available && s.call == -1 && s.camera == -1);
    assert(!presence_update(&m, "mac-a", "Mac A", "session-a", 1, true, -1, true, true, 0));
    assert(!presence_update(&m, "mac-b", "Mac B", "session-b", 1, true, 1, true, false, 0));
    s = presence_summary(&m, 0); assert(s.call == 1 && s.camera == 1 && s.automate && s.preview);
    assert(!presence_update(&m, "mac-a", "Mac A", "session-a", 2, false, -1, true, true, 1000));
    s = presence_summary(&m, 1000); assert(s.call == 1 && s.camera == 1 && s.automate);
    assert(!presence_update(&m, "mac-b", "Mac B", "session-b", 2, false, -1, true, false, 1000));
    s = presence_summary(&m, 1000); assert(s.call == 0 && s.camera == 0 && !s.automate);
    presence_model_t old = m;
    assert(presence_update(&m, "mac-a", "Mac A", "session-a", 2, true, 1, true, true, 2000));
    assert(!memcmp(&m, &old, sizeof(m))); // Duplicates never renew freshness.
    assert(presence_update(&m, "mac-a", "Mac A", "other-session", 1, true, 1, true, true, 2000));
    assert(presence_update(&m, "mac-c", "Mac C", "session-c", 1, true, 1, true, true, 2000));
    assert(presence_update(&m, "bad/id", "Mac C", "session-c", 1, true, 1, true, true, 2000));
    assert(presence_update(&m, "mac-a", "Mac A", "session-a", 3, false, 1, true, true, 2000));
    assert(!presence_update(&m, "mac-a", "Mac A", "session-a", 3, false, 0, true, true, 8500));
    s = presence_summary(&m, 9000); assert(s.available && s.call == -1 && s.camera == -1 && !s.automate);
    assert(!presence_update(&m, "mac-a", "Mac A", "session-a", 4, true, -1, true, true, 9000));
    s = presence_summary(&m, 9000); assert(s.call == 1 && s.camera == -1 && s.automate);
    assert(!presence_update(&m, "mac-b", "Mac B", "new-session", 1, true, 1, false, false, 9000));
    s = presence_summary(&m, 17000); assert(!s.available && !s.automate && s.call == -1);
    assert(!presence_update(&m, "mac-b", "Mac B", "new-session", 2, true, 1, false, false, 18000));
    s = presence_summary(&m, 18000); assert(s.call == 1 && s.camera == 1 && !s.automate);
    return 0;
}
