/* Integration fixture: the first VA surface imports normally. Report an
 * unadvertised modifier on the next export to exercise fallback on a mapped
 * YUV surface. The client checks feedback before sending any such buffer. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <va/va.h>
#include <va/va_drmcommon.h>

VAStatus vaExportSurfaceHandle(VADisplay dpy, VASurfaceID surface,
        uint32_t type, uint32_t flags, void *descriptor) {
    static unsigned exports;
    VAStatus (*real_export)(VADisplay, VASurfaceID, uint32_t, uint32_t, void *) =
        dlsym(RTLD_NEXT, "vaExportSurfaceHandle");
    if (!real_export) return VA_STATUS_ERROR_OPERATION_FAILED;
    VAStatus result = real_export(dpy, surface, type, flags, descriptor);
    if (type == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2 && result == VA_STATUS_SUCCESS && exports++ > 0) {
        VADRMPRIMESurfaceDescriptor *image = descriptor;
        for (uint32_t i = 0; i < image->num_objects; ++i)
            image->objects[i].drm_format_modifier = UINT64_MAX;
    }
    return result;
}
