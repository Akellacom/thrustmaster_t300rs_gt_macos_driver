#include "CUSBModeSwitch.h"
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>

// Verbose flag shared with CUSBModeSwitch.c via env var TM_VERBOSE.
static int vdev_verbose = -1;
static int vdev_verbose_on(void) {
    if (vdev_verbose < 0) {
        const char *v = getenv("TM_VERBOSE");
        vdev_verbose = (v && *v && *v != '0') ? 1 : 0;
    }
    return vdev_verbose;
}
#define VDBG(...) do { if (vdev_verbose_on()) printf(__VA_ARGS__); } while (0)

// We use IOHIDUserDeviceCreateWithProperties (macOS 10.15+)
// Requires com.apple.developer.hid.virtual.device entitlement,
// but this is bypassed with SIP disabled.

// Also try the older IOHIDUserDeviceCreate via dlsym as fallback
typedef IOHIDUserDeviceRef (*IOHIDUserDeviceCreateLegacyFn)(CFAllocatorRef, CFDictionaryRef);
typedef void (*IOHIDUserDeviceScheduleWithRunLoopLegacyFn)(IOHIDUserDeviceRef, CFRunLoopRef, CFStringRef);
typedef IOReturn (*IOHIDUserDeviceHandleReportLegacyFn)(IOHIDUserDeviceRef, const uint8_t *, CFIndex);

VirtualDeviceHandle virtual_device_create(const uint8_t *descriptor, size_t descriptor_len,
                                          const char *product_name) {
    return virtual_device_create_ex(descriptor, descriptor_len, 0, 0, 0, NULL, product_name);
}

VirtualDeviceHandle virtual_device_create_ex(const uint8_t *descriptor, size_t descriptor_len,
                                             uint16_t vendor_id, uint16_t product_id,
                                             uint16_t version,
                                             const char *manufacturer,
                                             const char *product_name) {
    CFDataRef descriptorData = CFDataCreate(kCFAllocatorDefault, descriptor, (CFIndex)descriptor_len);
    if (!descriptorData) {
        printf("[VirtualDevice-C] Failed to create descriptor CFData\n");
        return NULL;
    }

    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );

    CFDictionarySetValue(props, CFSTR(kIOHIDReportDescriptorKey), descriptorData);
    CFRelease(descriptorData);

    if (product_name) {
        CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, product_name, kCFStringEncodingUTF8);
        CFDictionarySetValue(props, CFSTR(kIOHIDProductKey), name);
        CFRelease(name);
    }

    if (manufacturer) {
        CFStringRef mfg = CFStringCreateWithCString(kCFAllocatorDefault, manufacturer, kCFStringEncodingUTF8);
        CFDictionarySetValue(props, CFSTR(kIOHIDManufacturerKey), mfg);
        CFRelease(mfg);
    }

    if (vendor_id != 0) {
        int32_t vid = (int32_t)vendor_id;
        CFNumberRef vidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vid);
        CFDictionarySetValue(props, CFSTR(kIOHIDVendorIDKey), vidRef);
        CFRelease(vidRef);
    }

    if (product_id != 0) {
        int32_t pid = (int32_t)product_id;
        CFNumberRef pidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pid);
        CFDictionarySetValue(props, CFSTR(kIOHIDProductIDKey), pidRef);
        CFRelease(pidRef);
    }

    if (version != 0) {
        int32_t ver = (int32_t)version;
        CFNumberRef verRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &ver);
        CFDictionarySetValue(props, CFSTR(kIOHIDVersionNumberKey), verRef);
        CFRelease(verRef);
    }

    // Primary usage page / usage — helps macOS categorize the device as a game controller
    {
        int32_t up = 0x01; // Generic Desktop
        int32_t us = 0x04; // Joystick
        CFNumberRef upRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &up);
        CFNumberRef usRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &us);
        CFDictionarySetValue(props, CFSTR(kIOHIDPrimaryUsagePageKey), upRef);
        CFDictionarySetValue(props, CFSTR(kIOHIDPrimaryUsageKey), usRef);
        CFRelease(upRef);
        CFRelease(usRef);
    }

    // IOHIDUserDeviceCreate occasionally returns NULL during transient kernel
    // state (right after USB re-enumeration, HID driver rebinds, etc.). Retry
    // each API a handful of times before giving up.
    const int MAX_ATTEMPTS = 6;
    const useconds_t RETRY_DELAY_US = 300000;  // 300ms

    // Resolve legacy once — dlsym across a few retries is just noise.
    void *dl_handle = dlopen(NULL, RTLD_LAZY);
    IOHIDUserDeviceCreateLegacyFn legacyCreate =
        (IOHIDUserDeviceCreateLegacyFn)dlsym(dl_handle, "IOHIDUserDeviceCreate");
    IOHIDUserDeviceScheduleWithRunLoopLegacyFn legacySchedule =
        (IOHIDUserDeviceScheduleWithRunLoopLegacyFn)dlsym(dl_handle, "IOHIDUserDeviceScheduleWithRunLoop");

    IOHIDUserDeviceRef device = NULL;

    for (int attempt = 1; attempt <= MAX_ATTEMPTS && !device; attempt++) {
        // Try modern API first
        device = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, props, 0);
        if (device) {
            VDBG("[VirtualDevice-C] Created via modern API (attempt %d)!\n", attempt);
            dispatch_queue_t queue = dispatch_queue_create(
                "com.thrustmaster.virtualdevice", DISPATCH_QUEUE_SERIAL);
            IOHIDUserDeviceSetDispatchQueue(device, queue);
            IOHIDUserDeviceActivate(device);
            break;
        }

        // Fallback: legacy API
        if (legacyCreate) {
            device = legacyCreate(kCFAllocatorDefault, props);
            if (device) {
                VDBG("[VirtualDevice-C] Created via legacy API (attempt %d)!\n", attempt);
                if (legacySchedule) {
                    legacySchedule(device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
                }
                break;
            }
        }

        VDBG("[VirtualDevice-C] Attempt %d/%d returned NULL — retrying in %dms…\n",
               attempt, MAX_ATTEMPTS, RETRY_DELAY_US / 1000);
        usleep(RETRY_DELAY_US);
    }

    CFRelease(props);

    if (device) return (VirtualDeviceHandle)device;

    // Swift caller prints a full user-facing troubleshooting message; keep the
    // C-side diagnostic behind TM_VERBOSE.
    VDBG("[VirtualDevice-C] All %d attempts failed\n", MAX_ATTEMPTS);
    return NULL;
}

void virtual_device_schedule(VirtualDeviceHandle handle, CFRunLoopRef runLoop) {
    // No-op for modern API (uses dispatch queue)
    // For legacy API this was already done in create
    (void)handle;
    (void)runLoop;
}

int virtual_device_send_report(VirtualDeviceHandle handle, const uint8_t *report, size_t report_len) {
    if (!handle) return -1;
    IOHIDUserDeviceRef device = (IOHIDUserDeviceRef)handle;

    // Use timestamped version (works with both legacy and modern)
    IOReturn result = IOHIDUserDeviceHandleReportWithTimeStamp(
        device, mach_absolute_time(), report, (CFIndex)report_len);

    return (result == kIOReturnSuccess) ? 0 : (int)result;
}

void virtual_device_destroy(VirtualDeviceHandle handle) {
    if (!handle) return;
    IOHIDUserDeviceRef device = (IOHIDUserDeviceRef)handle;
    IOHIDUserDeviceCancel(device);
    CFRelease(device);
    VDBG("[VirtualDevice-C] Virtual device destroyed\n");
}
