#include "PrivateMultitouchBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } Readout;
typedef struct {
    int frame; double time; int id, state, u1, u2; Readout normalized;
    float size; int zero; float angle, major, minor; Readout mm; int z[2]; float u3;
} Finger;
typedef int (*MTFrameCallback)(void *, Finger *, int, double, int);

static const char *const kFrameworkPath =
    "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";

static void *framework;
static CFArrayRef devices;
static _Atomic(void *) selected_device;
static _Atomic(EVTrackpadSampleHandler) sample_handler;
static pthread_mutex_t lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;

static CFArrayRef (*MTDeviceCreateList)(void);
static int (*MTDeviceGetSensorDimensions)(void *, int *, int *);
static void (*MTRegisterContactFrameCallback)(void *, MTFrameCallback);
static void (*MTUnregisterContactFrameCallback)(void *, MTFrameCallback);
static void (*MTDeviceStart)(void *, int);
static void (*MTDeviceStop)(void *);

static int emit(int count, int id, float x, float y) {
    EVTrackpadSampleHandler handler = atomic_load(&sample_handler);
    if (handler) handler(count, id, x, y);
    return 0;
}

static int contact_frame(void *device, Finger *fingers, int count, double timestamp, int frame) {
    (void)timestamp;
    (void)frame;
    if (device != atomic_load(&selected_device)) return 0;
    if (count < 0 || count > 32 || (count > 0 && fingers == NULL)) return emit(-1, 0, 0, 0);

    int active_count = 0;
    Finger *contact = NULL;
    for (int i = 0; i < count; i++) {
        if (fingers[i].state == 3 || fingers[i].state == 4) {
            active_count++;
            contact = &fingers[i];
        }
    }
    if (active_count != 1) return emit(active_count, 0, 0, 0);

    float x = contact->normalized.position.x;
    float y = contact->normalized.position.y;
    if (!isfinite(x) || !isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1) return emit(-1, 0, 0, 0);
    return emit(1, contact->id, x, y);
}

static int resolve_symbols(void) {
    if (!framework) framework = dlopen(kFrameworkPath, RTLD_NOW | RTLD_LOCAL);
    if (!framework) return -1;
    MTDeviceCreateList = dlsym(framework, "MTDeviceCreateList");
    MTDeviceGetSensorDimensions = dlsym(framework, "MTDeviceGetSensorDimensions");
    MTRegisterContactFrameCallback = dlsym(framework, "MTRegisterContactFrameCallback");
    MTUnregisterContactFrameCallback = dlsym(framework, "MTUnregisterContactFrameCallback");
    MTDeviceStart = dlsym(framework, "MTDeviceStart");
    MTDeviceStop = dlsym(framework, "MTDeviceStop");
    return MTDeviceCreateList && MTDeviceGetSensorDimensions && MTRegisterContactFrameCallback
        && MTUnregisterContactFrameCallback && MTDeviceStart && MTDeviceStop ? 0 : -2;
}

static void stop_locked(void) {
    void *device = atomic_exchange(&selected_device, NULL);
    if (device) {
        MTDeviceStop(device);
        MTUnregisterContactFrameCallback(device, contact_frame);
    }
    if (devices) {
        CFRelease(devices);
        devices = NULL;
    }
}

int32_t ev_capture_restart(void) {
    pthread_mutex_lock(&lifecycle_lock);
    if (resolve_symbols() != 0) {
        pthread_mutex_unlock(&lifecycle_lock);
        return -2;
    }
    stop_locked();
    devices = MTDeviceCreateList();
    if (!devices) {
        pthread_mutex_unlock(&lifecycle_lock);
        return -3;
    }
    for (CFIndex index = 0; index < CFArrayGetCount(devices); index++) {
        void *device = (void *)CFArrayGetValueAtIndex(devices, index);
        int rows = 0;
        int columns = 0;
        MTDeviceGetSensorDimensions(device, &rows, &columns);
        if (rows < 10) continue;
        atomic_store(&selected_device, device);
        MTRegisterContactFrameCallback(device, contact_frame);
        MTDeviceStart(device, 0);
        pthread_mutex_unlock(&lifecycle_lock);
        return 0;
    }
    CFRelease(devices);
    devices = NULL;
    pthread_mutex_unlock(&lifecycle_lock);
    return -3;
}

int32_t ev_capture_start(EVTrackpadSampleHandler handler) {
    atomic_store(&sample_handler, handler);
    int32_t result = ev_capture_restart();
    if (result != 0) atomic_store(&sample_handler, NULL);
    return result;
}

void ev_capture_stop(void) {
    pthread_mutex_lock(&lifecycle_lock);
    stop_locked();
    atomic_store(&sample_handler, NULL);
    pthread_mutex_unlock(&lifecycle_lock);
}

int32_t ev_capture_is_running(void) {
    return atomic_load(&selected_device) != NULL;
}
