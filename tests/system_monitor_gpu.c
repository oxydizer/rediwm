/* Optional NVML peer for the isolated monitor suite. No host GPU is queried. */
#include <stdio.h>
#include <stdlib.h>

static void trace(const char *event) {
    const char *path = getenv("REDIWM_TEST_GPU_TRACE");
    if (!path) return;
    FILE *out = fopen(path, "a");
    if (!out) return;
    fprintf(out, "%s\n", event);
    fclose(out);
}

unsigned nvmlInit_v2(void) { trace("init"); return 0; }
unsigned nvmlShutdown(void) { trace("shutdown"); return 0; }
unsigned nvmlDeviceGetCount_v2(unsigned *count) { *count = 1; return 0; }
unsigned nvmlDeviceGetHandleByIndex_v2(unsigned index, void **device) {
    if (index) return 2;
    *device = (void *)1;
    return 0;
}
unsigned nvmlDeviceGetTemperature(void *device, unsigned sensor, unsigned *degrees) {
    if (device != (void *)1 || sensor) return 2;
    const char *path = getenv("REDIWM_TEST_GPU_STATE");
    FILE *in = path ? fopen(path, "r") : NULL;
    if (!in) return 3;
    int value = -1;
    int read = fscanf(in, "%d", &value);
    fclose(in);
    if (read != 1 || value < 0) { trace("unavailable"); return 3; }
    *degrees = (unsigned)value;
    trace("temperature");
    return 0;
}
