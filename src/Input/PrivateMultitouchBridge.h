#ifndef EDGE_VOLUME_PRIVATE_MULTITOUCH_BRIDGE_H
#define EDGE_VOLUME_PRIVATE_MULTITOUCH_BRIDGE_H

#include <stdint.h>

typedef void (*EVTrackpadSampleHandler)(int32_t contact_count, int32_t contact_id, float x, float y);

int32_t ev_capture_start(EVTrackpadSampleHandler handler);
void ev_capture_stop(void);
int32_t ev_capture_restart(void);
int32_t ev_capture_is_running(void);

#endif
