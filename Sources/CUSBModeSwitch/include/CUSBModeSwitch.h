#ifndef CUSB_MODE_SWITCH_H
#define CUSB_MODE_SWITCH_H

#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>

/// Perform USB mode switch on Thrustmaster wheel.
int thrustmaster_mode_switch(uint16_t vendor_id, uint16_t product_id, uint16_t switch_value);

/// Check if a USB device with given VID/PID is present.
int thrustmaster_device_present(uint16_t vendor_id, uint16_t product_id);

/// Configure wheel via USB interrupt OUT endpoint.
/// Uses USBDeviceReEnumerate(capture) to detach the HID driver.
/// Returns 0 on success, negative on failure.
int thrustmaster_configure_wheel(uint16_t vendor_id, uint16_t product_id,
                                  uint16_t range_degrees, uint16_t gain);

/// Callback for USB input reports
typedef void (*usb_report_callback_t)(const uint8_t *data, int length, void *context);

/// Start direct USB I/O: capture device, configure FF, begin async input reads.
/// This REPLACES the HID driver — no IOHIDSystem, no cursor events.
/// Returns 0 on success. Callback is called for each input report on the given RunLoop.
int thrustmaster_usb_start(uint16_t vendor_id, uint16_t product_id,
                            uint16_t range_degrees, uint16_t gain,
                            usb_report_callback_t callback, void *context,
                            CFRunLoopRef runLoop);

/// Send FF command via USB interrupt OUT (64 bytes: report_id + 63 data)
int thrustmaster_usb_send_ff(const uint8_t *data, int length);

/// Upload and play a spring (centering) effect. strength: 0-100
int thrustmaster_ff_spring(uint8_t effect_id, uint16_t strength);

/// Upload and play a damper (resistance) effect. strength: 0-100
int thrustmaster_ff_damper(uint8_t effect_id, uint16_t strength);

/// Upload a constant-force effect. magnitude: signed -32767..32767.
/// Positive magnitude = torque to the right, negative = left.
/// Infinite duration until stopped/updated.
int thrustmaster_ff_constant(uint8_t effect_id, int16_t magnitude);

/// Update the magnitude of an already-playing constant-force effect
/// without resetting playback. Uses same format as upload — firmware
/// treats a fresh upload of the same id as "replace".
int thrustmaster_ff_constant_update(uint8_t effect_id, int16_t magnitude);

/// Upload a periodic sine effect. magnitude 0..32767, period_ms in ms.
/// Used for engine rumble and road texture vibration.
int thrustmaster_ff_sine(uint8_t effect_id, uint16_t magnitude, uint16_t period_ms);

/// Play an already uploaded effect
int thrustmaster_ff_play(uint8_t effect_id);

/// Stop an effect
int thrustmaster_ff_stop(uint8_t effect_id);

/// Stop USB I/O and release device back to system HID driver
void thrustmaster_usb_stop(void);

/// Live range update on the currently-captured USB interface.
/// Sends only the range packet — no re-enumeration. Requires thrustmaster_usb_start
/// to have succeeded. Returns 0 on success, negative otherwise.
int thrustmaster_set_range_live(uint16_t range_degrees);

/// Live gain update on the currently-captured USB interface.
/// Returns 0 on success.
int thrustmaster_set_gain_live(uint16_t gain);

/// Opaque handle for virtual HID device
typedef void* VirtualDeviceHandle;

/// Create a virtual HID device with the given report descriptor.
/// Returns handle on success, NULL on failure.
VirtualDeviceHandle virtual_device_create(const uint8_t *descriptor, size_t descriptor_len,
                                          const char *product_name);

/// Create a virtual HID device with full identity (VID/PID/version/manufacturer/product).
/// Pass 0 for any numeric field you want to omit. Pass NULL for strings to omit.
/// Returns handle on success, NULL on failure.
VirtualDeviceHandle virtual_device_create_ex(const uint8_t *descriptor, size_t descriptor_len,
                                             uint16_t vendor_id, uint16_t product_id,
                                             uint16_t version,
                                             const char *manufacturer,
                                             const char *product_name);

/// Send an input report to the virtual device.
/// Returns 0 on success.
int virtual_device_send_report(VirtualDeviceHandle handle, const uint8_t *report, size_t report_len);

/// Schedule the virtual device on the given run loop.
void virtual_device_schedule(VirtualDeviceHandle handle, CFRunLoopRef runLoop);

/// Destroy the virtual device.
void virtual_device_destroy(VirtualDeviceHandle handle);

/// POSIX shm_open shim (variadic in C, unavailable in Swift).
/// Returns a file descriptor or -1 on error. errno is set on failure.
int ets2_shm_open_ro(const char *name);

#endif
