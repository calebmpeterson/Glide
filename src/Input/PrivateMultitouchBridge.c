#include "PrivateMultitouchBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

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
static CFMutableArrayRef active_devices;
static _Atomic(uint32_t) active_device_count;
static _Atomic(EVTrackpadSampleHandler) sample_handler;
static CFMutableArrayRef actuators;
static pthread_mutex_t lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;

static CFArrayRef (*MTDeviceCreateList)(void);
static int (*MTDeviceGetSensorDimensions)(void *, int *, int *);
static void (*MTRegisterContactFrameCallback)(void *, MTFrameCallback);
static void (*MTUnregisterContactFrameCallback)(void *, MTFrameCallback);
static void (*MTDeviceStart)(void *, int);
static void (*MTDeviceStop)(void *);
static int (*MTDeviceGetDeviceID)(void *, uint64_t *);
static CFTypeRef (*MTActuatorCreateFromDeviceID)(uint64_t);
static int (*MTActuatorOpen)(CFTypeRef);
static int (*MTActuatorClose)(CFTypeRef);
static int (*MTActuatorActuate)(CFTypeRef, int32_t, uint32_t, float, float);

static uint64_t clock_ns(clockid_t clock_id) {
    struct timespec value;
    if (clock_gettime(clock_id, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000ULL + (uint64_t)value.tv_nsec;
}

static int emit(void *device, int count, int id, float x, float y, uint64_t wall_start, uint64_t cpu_start) {
    EVTrackpadSampleHandler handler = atomic_load(&sample_handler);
    if (handler) handler(count, id, x, y, (uintptr_t)device,
        clock_ns(CLOCK_MONOTONIC_RAW) - wall_start,
        clock_ns(CLOCK_THREAD_CPUTIME_ID) - cpu_start);
    return 0;
}

static int contact_frame(void *device, Finger *fingers, int count, double timestamp, int frame) {
    uint64_t filter_wall_start = clock_ns(CLOCK_MONOTONIC_RAW);
    uint64_t filter_cpu_start = clock_ns(CLOCK_THREAD_CPUTIME_ID);
    (void)timestamp;
    (void)frame;
    if (count < 0 || count > 32 || (count > 0 && fingers == NULL)) return emit(device, -1, 0, 0, 0, filter_wall_start, filter_cpu_start);

    int active_count = 0;
    Finger *contact = NULL;
    for (int i = 0; i < count; i++) {
        if (fingers[i].state == 3 || fingers[i].state == 4) {
            active_count++;
            contact = &fingers[i];
        }
    }
    if (active_count != 1) return emit(device, active_count, 0, 0, 0, filter_wall_start, filter_cpu_start);

    float x = contact->normalized.position.x;
    float y = contact->normalized.position.y;
    if (!isfinite(x) || !isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1) return emit(device, -1, 0, 0, 0, filter_wall_start, filter_cpu_start);
    return emit(device, 1, contact->id, x, y, filter_wall_start, filter_cpu_start);
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
    // Haptics are optional: capture keeps working if these symbols disappear.
    MTDeviceGetDeviceID = dlsym(framework, "MTDeviceGetDeviceID");
    MTActuatorCreateFromDeviceID = dlsym(framework, "MTActuatorCreateFromDeviceID");
    MTActuatorOpen = dlsym(framework, "MTActuatorOpen");
    MTActuatorClose = dlsym(framework, "MTActuatorClose");
    MTActuatorActuate = dlsym(framework, "MTActuatorActuate");
    return MTDeviceCreateList && MTDeviceGetSensorDimensions && MTRegisterContactFrameCallback
        && MTUnregisterContactFrameCallback && MTDeviceStart && MTDeviceStop ? 0 : -2;
}

static CFTypeRef open_actuator(void *device) {
    uint64_t id = 0;
    if (!MTDeviceGetDeviceID || !MTActuatorCreateFromDeviceID || !MTActuatorOpen || !MTActuatorClose || !MTActuatorActuate) return NULL;
    if (MTDeviceGetDeviceID(device, &id) != 0) return NULL;
    CFTypeRef actuator = MTActuatorCreateFromDeviceID(id);
    if (!actuator) return NULL;
    if (MTActuatorOpen(actuator) != 0) {
        CFRelease(actuator);
        return NULL;
    }
    return actuator;
}

static void stop_locked(void) {
    if (actuators) {
        for (CFIndex index = 0; index < CFArrayGetCount(actuators); index++) {
            CFTypeRef actuator = CFArrayGetValueAtIndex(actuators, index);
            if (actuator) {
                MTActuatorClose(actuator);
                CFRelease(actuator);
            }
        }
        CFRelease(actuators);
        actuators = NULL;
    }
    if (active_devices) {
        for (CFIndex index = 0; index < CFArrayGetCount(active_devices); index++) {
            void *device = (void *)CFArrayGetValueAtIndex(active_devices, index);
            MTDeviceStop(device);
            MTUnregisterContactFrameCallback(device, contact_frame);
        }
        CFRelease(active_devices);
        active_devices = NULL;
    }
    atomic_store(&active_device_count, 0);
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
    active_devices = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    if (!active_devices) {
        CFRelease(devices);
        devices = NULL;
        pthread_mutex_unlock(&lifecycle_lock);
        return -3;
    }
    actuators = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    for (CFIndex index = 0; index < CFArrayGetCount(devices); index++) {
        void *device = (void *)CFArrayGetValueAtIndex(devices, index);
        int rows = 0;
        int columns = 0;
        MTDeviceGetSensorDimensions(device, &rows, &columns);
        if (rows < 10) continue;
        CFArrayAppendValue(active_devices, device);
        if (actuators) CFArrayAppendValue(actuators, open_actuator(device));
        MTRegisterContactFrameCallback(device, contact_frame);
        MTDeviceStart(device, 0);
        atomic_fetch_add(&active_device_count, 1);
    }
    if (atomic_load(&active_device_count) == 0) {
        CFRelease(active_devices);
        active_devices = NULL;
        CFRelease(devices);
        devices = NULL;
        pthread_mutex_unlock(&lifecycle_lock);
        return -3;
    }
    pthread_mutex_unlock(&lifecycle_lock);
    return 0;
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

int32_t ev_haptic_actuate(uintptr_t device_id, int32_t actuation_id) {
    int32_t result = -1;
    pthread_mutex_lock(&lifecycle_lock);
    if (active_devices && actuators) {
        for (CFIndex index = 0; index < CFArrayGetCount(active_devices); index++) {
            if ((uintptr_t)CFArrayGetValueAtIndex(active_devices, index) != device_id) continue;
            CFTypeRef actuator = CFArrayGetValueAtIndex(actuators, index);
            if (actuator) result = MTActuatorActuate(actuator, actuation_id, 0, 0.0f, 0.0f);
            break;
        }
    }
    pthread_mutex_unlock(&lifecycle_lock);
    return result;
}

int32_t ev_capture_is_running(void) {
    return atomic_load(&active_device_count) > 0;
}
