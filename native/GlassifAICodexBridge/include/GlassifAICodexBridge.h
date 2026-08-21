#ifndef GLASSIFAI_CODEX_BRIDGE_H
#define GLASSIFAI_CODEX_BRIDGE_H
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

char *glassifai_codex_realtime_start(
    const char *access_token,
    const char *account_id,
    const char *sdp);
bool glassifai_codex_delegation_complete(
    const char *handoff_id,
    const char *text);
void glassifai_codex_realtime_close(void);
char *glassifai_codex_next_sideband_event(void);
char *glassifai_codex_sideband_status(void);
void glassifai_codex_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
