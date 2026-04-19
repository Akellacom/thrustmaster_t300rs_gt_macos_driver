#include "CUSBModeSwitch.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>

// Verbose logging: set TM_VERBOSE=1 to see enumeration/timing/packet details.
// Critical errors always print via printf(). Everything behind DBG() is gated.
static int tm_verbose = -1;
static int tm_verbose_on(void) {
    if (tm_verbose < 0) {
        const char *v = getenv("TM_VERBOSE");
        tm_verbose = (v && *v && *v != '0') ? 1 : 0;
    }
    return tm_verbose;
}
#define DBG(...) do { if (tm_verbose_on()) printf(__VA_ARGS__); } while (0)

int ets2_shm_open_ro(const char *name) {
    return shm_open(name, O_RDONLY, 0);
}

// Setup packets sent before mode switch (prevents T300RS crashes)
static uint8_t setup_0[] = {0x42, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
static uint8_t setup_1[] = {0x0a, 0x04, 0x90, 0x03, 0x00, 0x00, 0x00, 0x00};
static uint8_t setup_2[] = {0x0a, 0x04, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x00};
static uint8_t setup_3[] = {0x0a, 0x04, 0x12, 0x10, 0x00, 0x00, 0x00, 0x00};
static uint8_t setup_4[] = {0x0a, 0x04, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00};

static uint8_t *setup_packets[] = {setup_0, setup_1, setup_2, setup_3, setup_4};
static size_t setup_sizes[] = {9, 8, 8, 8, 8};

static io_service_t find_usb_device(uint16_t vendor_id, uint16_t product_id) {
    // Try IOUSBHostDevice first (modern macOS), then IOUSBDevice (legacy)
    const char *class_names[] = {"IOUSBHostDevice", "IOUSBDevice", NULL};

    for (int c = 0; class_names[c] != NULL; c++) {
        CFMutableDictionaryRef matching = IOServiceMatching(class_names[c]);
        if (!matching) continue;

        CFNumberRef vid = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt16Type, &vendor_id);
        CFNumberRef pid = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt16Type, &product_id);
        CFDictionarySetValue(matching, CFSTR(kUSBVendorID), vid);
        CFDictionarySetValue(matching, CFSTR(kUSBProductID), pid);
        CFRelease(vid);
        CFRelease(pid);

        io_iterator_t iterator = 0;
        kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
        if (kr != KERN_SUCCESS) continue;

        io_service_t service = IOIteratorNext(iterator);
        IOObjectRelease(iterator);

        if (service != 0) {
            DBG("[ModeSwitch-C] Found device via %s\n", class_names[c]);
            return service;
        }
    }
    return 0;
}

int thrustmaster_device_present(uint16_t vendor_id, uint16_t product_id) {
    io_service_t service = find_usb_device(vendor_id, product_id);
    if (service != 0) {
        IOObjectRelease(service);
        return 1;
    }
    return 0;
}

int thrustmaster_mode_switch(uint16_t vendor_id, uint16_t product_id, uint16_t switch_value) {
    io_service_t service = find_usb_device(vendor_id, product_id);
    if (service == 0) {
        DBG("[ModeSwitch-C] Device not found (VID=0x%04X, PID=0x%04X)\n", vendor_id, product_id);
        return -1;
    }

    // Create plugin interface
    IOCFPlugInInterface **pluginInterface = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &pluginInterface,
        &score
    );
    IOObjectRelease(service);

    if (kr != KERN_SUCCESS || pluginInterface == NULL) {
        DBG("[ModeSwitch-C] Failed to create plugin: 0x%08X\n", kr);
        return -2;
    }

    // Get USB device interface
    IOUSBDeviceInterface650 **deviceInterface = NULL;
    HRESULT hr = (*pluginInterface)->QueryInterface(pluginInterface,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650),
        (LPVOID *)&deviceInterface);

    if (hr != S_OK || deviceInterface == NULL) {
        // Try older interface
        IOUSBDeviceInterface **deviceInterface182 = NULL;
        hr = (*pluginInterface)->QueryInterface(pluginInterface,
            CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
            (LPVOID *)&deviceInterface182);
        (*pluginInterface)->Release(pluginInterface);

        if (hr != S_OK || deviceInterface182 == NULL) {
            DBG("[ModeSwitch-C] Failed to get device interface: 0x%08lX\n", (long)hr);
            return -3;
        }

        // Use the basic interface (fewer features but compatible)
        DBG("[ModeSwitch-C] Using basic IOUSBDeviceInterface\n");

        // Open device
        kr = (*deviceInterface182)->USBDeviceOpenSeize(deviceInterface182);
        if (kr != KERN_SUCCESS) {
            kr = (*deviceInterface182)->USBDeviceOpen(deviceInterface182);
            if (kr != KERN_SUCCESS) {
                DBG("[ModeSwitch-C] Cannot open device: 0x%08X\n", kr);
                (*deviceInterface182)->Release(deviceInterface182);
                return -4;
            }
        }
        DBG("[ModeSwitch-C] Device opened (basic interface)\n");

        // Set configuration
        kr = (*deviceInterface182)->SetConfiguration(deviceInterface182, 1);
        DBG("[ModeSwitch-C] SetConfiguration: 0x%08X\n", kr);

        // Send setup packets via interface
        IOUSBFindInterfaceRequest ifaceRequest;
        ifaceRequest.bInterfaceClass = kIOUSBFindInterfaceDontCare;
        ifaceRequest.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
        ifaceRequest.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
        ifaceRequest.bAlternateSetting = kIOUSBFindInterfaceDontCare;

        io_iterator_t ifaceIterator = 0;
        kr = (*deviceInterface182)->CreateInterfaceIterator(deviceInterface182, &ifaceRequest, &ifaceIterator);
        if (kr == KERN_SUCCESS) {
            io_service_t ifaceService = IOIteratorNext(ifaceIterator);
            IOObjectRelease(ifaceIterator);

            if (ifaceService != 0) {
                IOCFPlugInInterface **ifacePlugin = NULL;
                SInt32 ifaceScore = 0;
                kr = IOCreatePlugInInterfaceForService(ifaceService, kIOUSBInterfaceUserClientTypeID,
                    kIOCFPlugInInterfaceID, &ifacePlugin, &ifaceScore);
                IOObjectRelease(ifaceService);

                if (kr == KERN_SUCCESS && ifacePlugin != NULL) {
                    IOUSBInterfaceInterface550 **iface = NULL;
                    hr = (*ifacePlugin)->QueryInterface(ifacePlugin,
                        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID550),
                        (LPVOID *)&iface);
                    (*ifacePlugin)->Release(ifacePlugin);

                    if (hr == S_OK && iface != NULL) {
                        kr = (*iface)->USBInterfaceOpenSeize(iface);
                        if (kr != KERN_SUCCESS) {
                            kr = (*iface)->USBInterfaceOpen(iface);
                        }

                        if (kr == KERN_SUCCESS) {
                            // Find OUT endpoint
                            UInt8 numEndpoints = 0;
                            (*iface)->GetNumEndpoints(iface, &numEndpoints);
                            UInt8 outPipe = 0;
                            for (UInt8 i = 1; i <= numEndpoints; i++) {
                                UInt8 dir, num, tt;
                                UInt16 maxPkt;
                                UInt8 interval;
                                (*iface)->GetPipeProperties(iface, i, &dir, &num, &tt, &maxPkt, &interval);
                                if (dir == kUSBOut) {
                                    outPipe = i;
                                    DBG("[ModeSwitch-C] OUT endpoint: pipe %d, maxPacket %d\n", i, maxPkt);
                                    break;
                                }
                            }

                            if (outPipe != 0) {
                                for (int i = 0; i < 5; i++) {
                                    kr = (*iface)->WritePipe(iface, outPipe, setup_packets[i], (UInt32)setup_sizes[i]);
                                    DBG("[ModeSwitch-C] Setup packet %d: %s\n", i,
                                        kr == KERN_SUCCESS ? "OK" : "FAILED");
                                    usleep(10000);
                                }
                            } else {
                                DBG("[ModeSwitch-C] No OUT endpoint found\n");
                            }

                            (*iface)->USBInterfaceClose(iface);
                        }
                        (*iface)->Release(iface);
                    }
                }
            }
        }

        // Query model
        uint8_t modelBuf[16] = {0};
        IOUSBDevRequest modelReq;
        modelReq.bmRequestType = 0xC1;
        modelReq.bRequest = 0x49;
        modelReq.wValue = 0;
        modelReq.wIndex = 0;
        modelReq.wLength = sizeof(modelBuf);
        modelReq.pData = modelBuf;
        modelReq.wLenDone = 0;

        kr = (*deviceInterface182)->DeviceRequest(deviceInterface182, &modelReq);
        if (kr == KERN_SUCCESS) {
            DBG("[ModeSwitch-C] Model response (%d bytes):", modelReq.wLenDone);
            for (int i = 0; i < modelReq.wLenDone; i++) DBG(" %02X", modelBuf[i]);
            DBG("\n");
        } else {
            DBG("[ModeSwitch-C] Model query failed: 0x%08X\n", kr);
        }

        // Query firmware
        uint8_t fwBuf[8] = {0};
        IOUSBDevRequest fwReq;
        fwReq.bmRequestType = 0xC1;
        fwReq.bRequest = 0x56;
        fwReq.wValue = 0;
        fwReq.wIndex = 0;
        fwReq.wLength = sizeof(fwBuf);
        fwReq.pData = fwBuf;
        fwReq.wLenDone = 0;

        kr = (*deviceInterface182)->DeviceRequest(deviceInterface182, &fwReq);
        if (kr == KERN_SUCCESS) {
            DBG("[ModeSwitch-C] Firmware response (%d bytes):", fwReq.wLenDone);
            for (int i = 0; i < fwReq.wLenDone; i++) DBG(" %02X", fwBuf[i]);
            DBG("\n");
        } else {
            DBG("[ModeSwitch-C] Firmware query failed: 0x%08X\n", kr);
        }

        // Send mode switch
        DBG("[ModeSwitch-C] Sending mode switch (wValue=0x%04X)...\n", switch_value);
        IOUSBDevRequest switchReq;
        switchReq.bmRequestType = 0x41;
        switchReq.bRequest = 0x53;
        switchReq.wValue = switch_value;
        switchReq.wIndex = 0;
        switchReq.wLength = 0;
        switchReq.pData = NULL;
        switchReq.wLenDone = 0;

        kr = (*deviceInterface182)->DeviceRequest(deviceInterface182, &switchReq);
        DBG("[ModeSwitch-C] Mode switch result: 0x%08X %s\n", kr,
            kr == KERN_SUCCESS ? "(OK)" : "(expected if device disconnected)");

        (*deviceInterface182)->USBDeviceClose(deviceInterface182);
        (*deviceInterface182)->Release(deviceInterface182);
        return 0;
    }

    (*pluginInterface)->Release(pluginInterface);
    DBG("[ModeSwitch-C] Using IOUSBDeviceInterface650\n");

    // Open device with 650 interface
    kr = (*deviceInterface)->USBDeviceOpenSeize(deviceInterface);
    if (kr != KERN_SUCCESS) {
        kr = (*deviceInterface)->USBDeviceOpen(deviceInterface);
        if (kr != KERN_SUCCESS) {
            DBG("[ModeSwitch-C] Cannot open device: 0x%08X\n", kr);
            (*deviceInterface)->Release(deviceInterface);
            return -4;
        }
    }
    DBG("[ModeSwitch-C] Device opened (650 interface)\n");

    kr = (*deviceInterface)->SetConfiguration(deviceInterface, 1);
    DBG("[ModeSwitch-C] SetConfiguration: 0x%08X\n", kr);

    // Send setup packets via interface
    IOUSBFindInterfaceRequest ifaceRequest;
    ifaceRequest.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    ifaceRequest.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    ifaceRequest.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    ifaceRequest.bAlternateSetting = kIOUSBFindInterfaceDontCare;

    io_iterator_t ifaceIterator = 0;
    kr = (*deviceInterface)->CreateInterfaceIterator(deviceInterface, &ifaceRequest, &ifaceIterator);
    if (kr == KERN_SUCCESS) {
        io_service_t ifaceService = IOIteratorNext(ifaceIterator);
        IOObjectRelease(ifaceIterator);

        if (ifaceService != 0) {
            IOCFPlugInInterface **ifacePlugin = NULL;
            SInt32 ifaceScore = 0;
            kr = IOCreatePlugInInterfaceForService(ifaceService, kIOUSBInterfaceUserClientTypeID,
                kIOCFPlugInInterfaceID, &ifacePlugin, &ifaceScore);
            IOObjectRelease(ifaceService);

            if (kr == KERN_SUCCESS && ifacePlugin != NULL) {
                IOUSBInterfaceInterface550 **iface = NULL;
                hr = (*ifacePlugin)->QueryInterface(ifacePlugin,
                    CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID550),
                    (LPVOID *)&iface);
                (*ifacePlugin)->Release(ifacePlugin);

                if (hr == S_OK && iface != NULL) {
                    kr = (*iface)->USBInterfaceOpenSeize(iface);
                    if (kr != KERN_SUCCESS) kr = (*iface)->USBInterfaceOpen(iface);

                    if (kr == KERN_SUCCESS) {
                        UInt8 numEndpoints = 0;
                        (*iface)->GetNumEndpoints(iface, &numEndpoints);
                        UInt8 outPipe = 0;
                        for (UInt8 i = 1; i <= numEndpoints; i++) {
                            UInt8 dir, num, tt;
                            UInt16 maxPkt;
                            UInt8 interval;
                            (*iface)->GetPipeProperties(iface, i, &dir, &num, &tt, &maxPkt, &interval);
                            if (dir == kUSBOut) { outPipe = i; break; }
                        }
                        if (outPipe != 0) {
                            for (int i = 0; i < 5; i++) {
                                kr = (*iface)->WritePipe(iface, outPipe, setup_packets[i], (UInt32)setup_sizes[i]);
                                DBG("[ModeSwitch-C] Setup packet %d: %s\n", i,
                                    kr == KERN_SUCCESS ? "OK" : "FAILED");
                                usleep(10000);
                            }
                        }
                        (*iface)->USBInterfaceClose(iface);
                    }
                    (*iface)->Release(iface);
                }
            }
        }
    }

    // Query model
    uint8_t modelBuf[16] = {0};
    IOUSBDevRequest modelReq;
    modelReq.bmRequestType = 0xC1;
    modelReq.bRequest = 0x49;
    modelReq.wValue = 0;
    modelReq.wIndex = 0;
    modelReq.wLength = sizeof(modelBuf);
    modelReq.pData = modelBuf;
    modelReq.wLenDone = 0;

    kr = (*deviceInterface)->DeviceRequest(deviceInterface, &modelReq);
    if (kr == KERN_SUCCESS) {
        DBG("[ModeSwitch-C] Model (%d bytes):", modelReq.wLenDone);
        for (int i = 0; i < modelReq.wLenDone; i++) DBG(" %02X", modelBuf[i]);
        DBG("\n");
    } else {
        DBG("[ModeSwitch-C] Model query: 0x%08X\n", kr);
    }

    // Send mode switch
    DBG("[ModeSwitch-C] Sending mode switch (wValue=0x%04X)...\n", switch_value);
    IOUSBDevRequest switchReq;
    switchReq.bmRequestType = 0x41;
    switchReq.bRequest = 0x53;
    switchReq.wValue = switch_value;
    switchReq.wIndex = 0;
    switchReq.wLength = 0;
    switchReq.pData = NULL;
    switchReq.wLenDone = 0;

    kr = (*deviceInterface)->DeviceRequest(deviceInterface, &switchReq);
    DBG("[ModeSwitch-C] Mode switch: 0x%08X\n", kr);

    (*deviceInterface)->USBDeviceClose(deviceInterface);
    (*deviceInterface)->Release(deviceInterface);
    return 0;
}

// MARK: - Wheel Configuration via USB Interrupt OUT
// Linux hid-tmff2 sends via interrupt OUT (usbhid_submit_report → urbout).
// SET_REPORT control pipe is ACKed but IGNORED by T300RS firmware.
// macOS IOHIDDeviceSetReport clips data to original descriptor (62 bytes),
// but firmware needs 63 bytes (per Linux fixed descriptor).
// Solution: USBInterfaceOpenSeize to take interface from HID driver,
// write 63 bytes via WritePipe to interrupt OUT, then release.

int thrustmaster_configure_wheel(uint16_t vendor_id, uint16_t product_id,
                                  uint16_t range_degrees, uint16_t gain) {
    DBG("[WheelConfig-C] Waiting for device...\n");

    io_service_t service = 0;
    for (int attempt = 0; attempt < 500; attempt++) {
        usleep(10000);
        service = find_usb_device(vendor_id, product_id);
        if (service != 0) {
            DBG("[WheelConfig-C] Device found at ~%dms\n", attempt * 10);
            break;
        }
    }
    if (service == 0) { DBG("[WheelConfig-C] Timeout\n"); return -1; }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !plug) return -2;

    IOUSBDeviceInterface650 **dev = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (hr != S_OK || !dev) return -3;

    kr = (*dev)->USBDeviceOpenSeize(dev);
    if (kr != KERN_SUCCESS) kr = (*dev)->USBDeviceOpen(dev);
    if (kr != KERN_SUCCESS) {
        DBG("[WheelConfig-C] Cannot open device: 0x%08X\n", kr);
        (*dev)->Release(dev);
        return -4;
    }

    // Force re-enumeration with CAPTURE — detaches HID driver, gives us exclusive access
    DBG("[WheelConfig-C] Re-enumerating with capture to detach HID driver...\n");
    kr = (*dev)->USBDeviceReEnumerate(dev, kUSBReEnumerateCaptureDeviceMask);
    DBG("[WheelConfig-C] ReEnumerate: 0x%08X\n", kr);

    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);

    if (kr != KERN_SUCCESS) {
        DBG("[WheelConfig-C] ReEnumerate failed\n");
        return -5;
    }

    // Wait for device to re-appear after re-enumeration
    usleep(500000);  // 500ms
    service = 0;
    for (int attempt = 0; attempt < 300; attempt++) {
        usleep(10000);
        service = find_usb_device(vendor_id, product_id);
        if (service != 0) {
            DBG("[WheelConfig-C] Device back at ~%dms after re-enum\n", attempt * 10);
            break;
        }
    }
    if (service == 0) { DBG("[WheelConfig-C] Device lost after re-enum\n"); return -6; }

    // Now open device — we should have exclusive access (captured)
    plug = NULL;
    kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !plug) return -7;

    dev = NULL;
    hr = (*plug)->QueryInterface(plug,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (hr != S_OK || !dev) return -8;

    kr = (*dev)->USBDeviceOpen(dev);
    if (kr != KERN_SUCCESS) {
        DBG("[WheelConfig-C] Cannot reopen device: 0x%08X\n", kr);
        (*dev)->Release(dev);
        return -9;
    }

    // Set configuration (interfaces are created after this)
    kr = (*dev)->SetConfiguration(dev, 1);
    DBG("[WheelConfig-C] SetConfiguration: 0x%08X\n", kr);

    // Open interface — HID driver should NOT have it (we captured the device)
    IOUSBFindInterfaceRequest ifReq = {
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare
    };
    io_iterator_t iter = 0;
    kr = (*dev)->CreateInterfaceIterator(dev, &ifReq, &iter);
    if (kr != KERN_SUCCESS) {
        (*dev)->USBDeviceClose(dev); (*dev)->Release(dev);
        return -10;
    }
    io_service_t ifSvc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (ifSvc == 0) {
        (*dev)->USBDeviceClose(dev); (*dev)->Release(dev);
        return -11;
    }

    IOCFPlugInInterface **ifPlug = NULL;
    SInt32 s = 0;
    kr = IOCreatePlugInInterfaceForService(ifSvc, kIOUSBInterfaceUserClientTypeID,
        kIOCFPlugInInterfaceID, &ifPlug, &s);
    IOObjectRelease(ifSvc);
    if (kr != KERN_SUCCESS || !ifPlug) {
        (*dev)->USBDeviceClose(dev); (*dev)->Release(dev);
        return -12;
    }

    IOUSBInterfaceInterface550 **iface = NULL;
    hr = (*ifPlug)->QueryInterface(ifPlug,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID550), (LPVOID *)&iface);
    (*ifPlug)->Release(ifPlug);
    if (hr != S_OK || !iface) {
        (*dev)->USBDeviceClose(dev); (*dev)->Release(dev);
        return -13;
    }

    kr = (*iface)->USBInterfaceOpen(iface);
    if (kr != KERN_SUCCESS) {
        DBG("[WheelConfig-C] Interface open failed: 0x%08X\n", kr);
        (*iface)->Release(iface);
        (*dev)->USBDeviceClose(dev); (*dev)->Release(dev);
        return -14;
    }
    DBG("[WheelConfig-C] Interface opened (exclusive via capture)!\n");

    // Find interrupt OUT pipe
    UInt8 numEP = 0;
    (*iface)->GetNumEndpoints(iface, &numEP);
    UInt8 outPipe = 0;
    for (UInt8 i = 1; i <= numEP; i++) {
        UInt8 dir, num, tt; UInt16 maxPkt; UInt8 interval;
        (*iface)->GetPipeProperties(iface, i, &dir, &num, &tt, &maxPkt, &interval);
        if (dir == kUSBOut) {
            outPipe = i;
            DBG("[WheelConfig-C] OUT pipe %d, maxPacket=%d\n", i, maxPkt);
            break;
        }
    }
    if (outPipe == 0) {
        (*iface)->USBInterfaceClose(iface); (*iface)->Release(iface);
        (*dev)->USBDeviceClose(dev); (*dev)->Release(dev);
        return -15;
    }

    // Send FF commands via interrupt OUT — 64 bytes like Linux driver
    uint8_t buf[64];
    int ok = 0;

    // 1. Open FF
    memset(buf, 0, 64);
    buf[0] = 0x60; buf[1] = 0x01; buf[2] = 0x05;
    kr = (*iface)->WritePipe(iface, outPipe, buf, 64);
    if (kr == KERN_SUCCESS) ok++;
    DBG("[WheelConfig-C] FF open: %s (0x%08X)\n", kr == KERN_SUCCESS ? "OK" : "FAIL", kr);
    usleep(50000);

    // 2. Range (value * 0x3C per Linux driver)
    uint16_t scaled = range_degrees * 0x3C;
    memset(buf, 0, 64);
    buf[0] = 0x60; buf[1] = 0x08; buf[2] = 0x11;
    buf[3] = (uint8_t)(scaled & 0xFF);
    buf[4] = (uint8_t)(scaled >> 8);
    kr = (*iface)->WritePipe(iface, outPipe, buf, 64);
    if (kr == KERN_SUCCESS) ok++;
    DBG("[WheelConfig-C] Range %d° (scaled=%d): %s (0x%08X)\n",
        range_degrees, scaled, kr == KERN_SUCCESS ? "OK" : "FAIL", kr);
    usleep(50000);

    // 3. Gain
    memset(buf, 0, 64);
    buf[0] = 0x60; buf[1] = 0x02; buf[2] = (uint8_t)(gain >> 8);
    kr = (*iface)->WritePipe(iface, outPipe, buf, 64);
    if (kr == KERN_SUCCESS) ok++;
    DBG("[WheelConfig-C] Gain: %s (0x%08X)\n", kr == KERN_SUCCESS ? "OK" : "FAIL", kr);

    // Release everything — device will re-enumerate normally, HID driver reclaims
    (*iface)->USBInterfaceClose(iface);
    (*iface)->Release(iface);

    // Release capture so HID driver can claim
    DBG("[WheelConfig-C] Releasing device capture...\n");
    (*dev)->USBDeviceReEnumerate(dev, kUSBReEnumerateReleaseDeviceMask);
    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);

    DBG("[WheelConfig-C] Done (%d/3 OK) — device will re-enumerate for HID\n", ok);
    return ok == 3 ? 0 : -1;
}

// MARK: - Direct USB I/O (replaces HID driver entirely)
// Captures device, reads input via interrupt IN, writes FF via interrupt OUT.
// No IOHIDSystem involvement = no cursor movement from wheel axes.

static IOUSBDeviceInterface650 **g_usb_dev = NULL;
static IOUSBInterfaceInterface550 **g_usb_iface = NULL;
static UInt8 g_in_pipe = 0;
static UInt8 g_out_pipe = 0;
static uint8_t g_read_buf[64];
static usb_report_callback_t g_report_callback = NULL;
static void *g_report_context = NULL;

static void usb_read_completion(void *refcon, IOReturn result, void *arg0) {
    if (result == kIOReturnSuccess && g_report_callback) {
        int len = (int)(uintptr_t)arg0;
        g_report_callback(g_read_buf, len, g_report_context);
    } else if (result == kIOReturnAborted) {
        // Pipe was aborted (device disconnected or stop called)
        DBG("[USB-IO] Read aborted\n");
        return;
    } else if (result != kIOReturnSuccess) {
        DBG("[USB-IO] Read error: 0x%08X\n", result);
    }

    // Re-arm async read
    if (g_usb_iface && g_in_pipe) {
        UInt32 size = sizeof(g_read_buf);
        (*g_usb_iface)->ReadPipeAsync(g_usb_iface, g_in_pipe,
            g_read_buf, size, usb_read_completion, NULL);
    }
}

int thrustmaster_usb_start(uint16_t vendor_id, uint16_t product_id,
                            uint16_t range_degrees, uint16_t gain,
                            usb_report_callback_t callback, void *context,
                            CFRunLoopRef runLoop) {
    DBG("[USB-IO] Starting direct USB driver...\n");
    g_report_callback = callback;
    g_report_context = context;

    // Find device
    io_service_t service = find_usb_device(vendor_id, product_id);
    if (service == 0) { DBG("[USB-IO] Device not found\n"); return -1; }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !plug) return -2;

    HRESULT hr = (*plug)->QueryInterface(plug,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&g_usb_dev);
    (*plug)->Release(plug);
    if (hr != S_OK || !g_usb_dev) return -3;

    kr = (*g_usb_dev)->USBDeviceOpenSeize(g_usb_dev);
    if (kr != KERN_SUCCESS) kr = (*g_usb_dev)->USBDeviceOpen(g_usb_dev);
    if (kr != KERN_SUCCESS) {
        DBG("[USB-IO] Cannot open device: 0x%08X\n", kr);
        (*g_usb_dev)->Release(g_usb_dev); g_usb_dev = NULL;
        return -4;
    }

    // Force re-enumerate with capture — detaches HID driver
    DBG("[USB-IO] Capturing device (detaching HID driver)...\n");
    kr = (*g_usb_dev)->USBDeviceReEnumerate(g_usb_dev, kUSBReEnumerateCaptureDeviceMask);
    DBG("[USB-IO] ReEnumerate(capture): 0x%08X\n", kr);
    (*g_usb_dev)->USBDeviceClose(g_usb_dev);
    (*g_usb_dev)->Release(g_usb_dev);
    g_usb_dev = NULL;

    if (kr != KERN_SUCCESS) return -5;

    // Wait for device to re-appear
    usleep(500000);
    service = 0;
    for (int i = 0; i < 300; i++) {
        usleep(10000);
        service = find_usb_device(vendor_id, product_id);
        if (service) { DBG("[USB-IO] Device back at ~%dms\n", i * 10); break; }
    }
    if (!service) { DBG("[USB-IO] Device lost\n"); return -6; }

    // Reopen
    plug = NULL;
    kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !plug) return -7;

    hr = (*plug)->QueryInterface(plug,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&g_usb_dev);
    (*plug)->Release(plug);
    if (hr != S_OK || !g_usb_dev) return -8;

    kr = (*g_usb_dev)->USBDeviceOpen(g_usb_dev);
    if (kr != KERN_SUCCESS) {
        DBG("[USB-IO] Cannot reopen: 0x%08X\n", kr);
        (*g_usb_dev)->Release(g_usb_dev); g_usb_dev = NULL;
        return -9;
    }

    kr = (*g_usb_dev)->SetConfiguration(g_usb_dev, 1);
    DBG("[USB-IO] SetConfiguration: 0x%08X\n", kr);

    // Open interface
    IOUSBFindInterfaceRequest ifReq = {
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare
    };
    io_iterator_t iter = 0;
    kr = (*g_usb_dev)->CreateInterfaceIterator(g_usb_dev, &ifReq, &iter);
    if (kr != KERN_SUCCESS) return -10;
    io_service_t ifSvc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!ifSvc) return -11;

    IOCFPlugInInterface **ifPlug = NULL;
    SInt32 s = 0;
    kr = IOCreatePlugInInterfaceForService(ifSvc, kIOUSBInterfaceUserClientTypeID,
        kIOCFPlugInInterfaceID, &ifPlug, &s);
    IOObjectRelease(ifSvc);
    if (kr != KERN_SUCCESS || !ifPlug) return -12;

    hr = (*ifPlug)->QueryInterface(ifPlug,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID550), (LPVOID *)&g_usb_iface);
    (*ifPlug)->Release(ifPlug);
    if (hr != S_OK || !g_usb_iface) return -13;

    kr = (*g_usb_iface)->USBInterfaceOpen(g_usb_iface);
    if (kr != KERN_SUCCESS) {
        DBG("[USB-IO] Interface open failed: 0x%08X\n", kr);
        (*g_usb_iface)->Release(g_usb_iface); g_usb_iface = NULL;
        return -14;
    }
    DBG("[USB-IO] Interface opened (exclusive, no HID driver)\n");

    // Find IN and OUT pipes
    UInt8 numEP = 0;
    (*g_usb_iface)->GetNumEndpoints(g_usb_iface, &numEP);
    for (UInt8 i = 1; i <= numEP; i++) {
        UInt8 dir, num, tt; UInt16 maxPkt; UInt8 interval;
        (*g_usb_iface)->GetPipeProperties(g_usb_iface, i, &dir, &num, &tt, &maxPkt, &interval);
        if (dir == kUSBIn && g_in_pipe == 0) {
            g_in_pipe = i;
            DBG("[USB-IO] IN pipe %d, maxPacket=%d\n", i, maxPkt);
        }
        if (dir == kUSBOut && g_out_pipe == 0) {
            g_out_pipe = i;
            DBG("[USB-IO] OUT pipe %d, maxPacket=%d\n", i, maxPkt);
        }
    }
    if (!g_in_pipe || !g_out_pipe) {
        DBG("[USB-IO] Missing endpoints (in=%d out=%d)\n", g_in_pipe, g_out_pipe);
        thrustmaster_usb_stop();
        return -15;
    }

    // Send FF commands via interrupt OUT
    uint8_t buf[64];

    // Open FF
    memset(buf, 0, 64);
    buf[0] = 0x60; buf[1] = 0x01; buf[2] = 0x05;
    kr = (*g_usb_iface)->WritePipe(g_usb_iface, g_out_pipe, buf, 64);
    DBG("[USB-IO] FF open: %s\n", kr == KERN_SUCCESS ? "OK" : "FAIL");
    usleep(50000);

    // Range
    uint16_t scaled = range_degrees * 0x3C;
    memset(buf, 0, 64);
    buf[0] = 0x60; buf[1] = 0x08; buf[2] = 0x11;
    buf[3] = (uint8_t)(scaled & 0xFF); buf[4] = (uint8_t)(scaled >> 8);
    kr = (*g_usb_iface)->WritePipe(g_usb_iface, g_out_pipe, buf, 64);
    DBG("[USB-IO] Range %d°: %s\n", range_degrees, kr == KERN_SUCCESS ? "OK" : "FAIL");
    usleep(50000);

    // Gain
    memset(buf, 0, 64);
    buf[0] = 0x60; buf[1] = 0x02; buf[2] = (uint8_t)(gain >> 8);
    kr = (*g_usb_iface)->WritePipe(g_usb_iface, g_out_pipe, buf, 64);
    DBG("[USB-IO] Gain: %s\n", kr == KERN_SUCCESS ? "OK" : "FAIL");

    // Schedule async event source on the provided run loop
    CFRunLoopSourceRef eventSource = NULL;
    kr = (*g_usb_iface)->CreateInterfaceAsyncEventSource(g_usb_iface, &eventSource);
    if (kr != KERN_SUCCESS || !eventSource) {
        DBG("[USB-IO] Failed to create async source: 0x%08X\n", kr);
        thrustmaster_usb_stop();
        return -16;
    }
    CFRunLoopAddSource(runLoop, eventSource, kCFRunLoopDefaultMode);

    // Start first async read
    UInt32 readSize = sizeof(g_read_buf);
    kr = (*g_usb_iface)->ReadPipeAsync(g_usb_iface, g_in_pipe,
        g_read_buf, readSize, usb_read_completion, NULL);
    if (kr != KERN_SUCCESS) {
        DBG("[USB-IO] ReadPipeAsync failed: 0x%08X\n", kr);
        thrustmaster_usb_stop();
        return -17;
    }

    DBG("[USB-IO] Direct USB I/O active — no HID driver, no cursor events\n");
    return 0;
}

int thrustmaster_usb_send_ff(const uint8_t *data, int length) {
    if (!g_usb_iface || !g_out_pipe) return -1;
    uint8_t buf[64];
    memset(buf, 0, 64);
    int copy = length < 64 ? length : 64;
    memcpy(buf, data, copy);
    return (*g_usb_iface)->WritePipe(g_usb_iface, g_out_pipe, buf, 64);
}

// FF effect helpers — matching exact Linux hid-tmff2 packet format.
// All packets: [0x60(reportID), 63 bytes data] = 64 bytes on interrupt OUT.

int thrustmaster_ff_spring(uint8_t effect_id, uint16_t strength) {
    if (!g_usb_iface || !g_out_pipe) return -1;

    // Exponential scaling for more noticeable difference at low values
    uint32_t s = strength;
    uint16_t coeff = (uint16_t)(s * s * 0x7FFF / 10000);  // 10→327, 50→8191, 100→32767
    uint16_t sat = (uint16_t)(s * 0x6AA6 / 100);  // scale saturation with strength
    static uint8_t hardcoded[] = {0xFE, 0xFF, 0xFE, 0xFF, 0xFE, 0xFF, 0xFE, 0xFF};

    // Packet format: t300rs_packet_condition
    // header: [zero=0, id=effect_id, code=0x64]
    // right_coeff(2), left_coeff(2), right_deadband(2), left_deadband(2)
    // right_saturation(2), left_saturation(2), hardcoded(8)
    // max_right_sat(2), max_left_sat(2), type(1)
    // timing: start_marker(1), duration(2), zero(2), offset(2), zero(1)
    uint8_t buf[64];
    memset(buf, 0, 64);
    buf[0] = 0x60;  // report ID
    // header
    buf[1] = 0x00;  // zero
    buf[2] = effect_id;  // effect ID (1-based)
    buf[3] = 0x64;  // condition command
    // right_coeff LE
    buf[4] = coeff & 0xFF; buf[5] = coeff >> 8;
    // left_coeff LE
    buf[6] = coeff & 0xFF; buf[7] = coeff >> 8;
    // deadbands = 0 (bytes 8-11)
    // right_saturation
    buf[12] = sat & 0xFF; buf[13] = sat >> 8;
    // left_saturation
    buf[14] = sat & 0xFF; buf[15] = sat >> 8;
    // hardcoded values
    memcpy(&buf[16], hardcoded, 8);
    // max_right_saturation
    buf[24] = sat & 0xFF; buf[25] = sat >> 8;
    // max_left_saturation
    buf[26] = sat & 0xFF; buf[27] = sat >> 8;
    // type: 0x06 = spring
    buf[28] = 0x06;
    // timing: infinite duration
    buf[29] = 0x4F;  // start marker
    buf[30] = 0xFF; buf[31] = 0xFF;  // duration = infinite
    // offset = 0 (bytes 32-35)

    IOReturn kr = (*g_usb_iface)->WritePipe(g_usb_iface, g_out_pipe, buf, 64);
    DBG("[FF-USB] Spring (id=%d, str=%d%%): %s\n",
        effect_id, strength, kr == KERN_SUCCESS ? "OK" : "FAIL");
    return kr;
}

int thrustmaster_ff_damper(uint8_t effect_id, uint16_t strength) {
    if (!g_usb_iface || !g_out_pipe) return -1;

    // Exponential scaling: low values feel different, high values are strong
    uint32_t s = strength;
    uint16_t coeff = (uint16_t)(s * s * 0x7FFF / 10000);  // 10→327, 30→2948, 50→8191, 100→32767
    uint16_t sat = (uint16_t)(s * 0x7FFC / 100);  // scale saturation too
    static uint8_t hardcoded[] = {0xFE, 0xFF, 0xFE, 0xFF, 0xFE, 0xFF, 0xFE, 0xFF};

    uint8_t buf[64];
    memset(buf, 0, 64);
    buf[0] = 0x60;
    buf[1] = 0x00;
    buf[2] = effect_id;
    buf[3] = 0x64;  // condition command
    buf[4] = coeff & 0xFF; buf[5] = coeff >> 8;
    buf[6] = coeff & 0xFF; buf[7] = coeff >> 8;
    buf[12] = sat & 0xFF; buf[13] = sat >> 8;
    buf[14] = sat & 0xFF; buf[15] = sat >> 8;
    memcpy(&buf[16], hardcoded, 8);
    buf[24] = sat & 0xFF; buf[25] = sat >> 8;
    buf[26] = sat & 0xFF; buf[27] = sat >> 8;
    buf[28] = 0x07;  // type: damper/friction
    buf[29] = 0x4F;
    buf[30] = 0xFF; buf[31] = 0xFF;

    IOReturn kr = (*g_usb_iface)->WritePipe(g_usb_iface, g_out_pipe, buf, 64);
    DBG("[FF-USB] Damper (id=%d, str=%d%%): %s\n",
        effect_id, strength, kr == KERN_SUCCESS ? "OK" : "FAIL");
    return kr;
}

// Upload a constant-force effect.
// Linux t300rs_packet_constant: code 0x6A, level (s16 LE) at offset 4.
// Layout mirrors what Linux hid-tmt300rs.c produces; infinite duration 0xFFFF.
static int ff_constant_inner(uint8_t effect_id, int16_t magnitude) {
    if (!g_usb_iface || !g_out_pipe) return -1;
    // Halve the magnitude — Linux driver and Windows do this for wheel scaling.
    int32_t lvl = magnitude / 2;
    if (lvl > 32767) lvl = 32767;
    if (lvl < -32768) lvl = -32768;
    uint16_t lvl_u = (uint16_t)((int16_t)lvl);

    uint8_t buf[64];
    memset(buf, 0, 64);
    buf[0] = 0x60;                  // report ID
    buf[1] = 0x00;                  // zero marker
    buf[2] = effect_id;             // effect ID (1-based)
    buf[3] = 0x6A;                  // CONSTANT
    buf[4] = lvl_u & 0xFF;          // level LE
    buf[5] = (lvl_u >> 8) & 0xFF;
    // bytes 6..13: envelope (attack/fade) — zero for plain constant
    buf[14] = 0x00;                 // effect_type
    buf[15] = 0x4F;                 // timing start marker
    buf[16] = 0xFF; buf[17] = 0xFF; // duration = infinite
    // bytes 18..22: offset/padding stay zero
    buf[23] = 0xFF; buf[24] = 0xFF; // end marker

    return (*g_usb_iface)->WritePipe(g_usb_iface, g_out_pipe, buf, 64);
}

int thrustmaster_ff_constant(uint8_t effect_id, int16_t magnitude) {
    int kr = ff_constant_inner(effect_id, magnitude);
    if (kr == 0) {
        // First upload also needs a play command.
        thrustmaster_ff_play(effect_id);
    }
    return kr;
}

int thrustmaster_ff_constant_update(uint8_t effect_id, int16_t magnitude) {
    // Re-upload replaces in place; firmware keeps playing.
    return ff_constant_inner(effect_id, magnitude);
}

// Periodic sine effect.
// Linux t300rs_packet_periodic: code 0x6B for periodic, type byte selects waveform.
// Format (offsets after [0x60, 0x00, id, code] header):
//   magnitude s16, offset s16, phase s16, period s16, duration s16, ...
// We follow the layout pattern used for constant: level at 4, timing at 15.
static int ff_periodic_inner(uint8_t effect_id, uint8_t waveform_type,
                              uint16_t magnitude, uint16_t period_ms) {
    if (!g_usb_iface || !g_out_pipe) return -1;
    if (magnitude > 0x7FFF) magnitude = 0x7FFF;
    if (period_ms < 2) period_ms = 2;

    uint8_t buf[64];
    memset(buf, 0, 64);
    buf[0] = 0x60;
    buf[1] = 0x00;
    buf[2] = effect_id;
    buf[3] = 0x6B;                  // PERIODIC
    // magnitude LE
    buf[4] = magnitude & 0xFF;
    buf[5] = (magnitude >> 8) & 0xFF;
    // offset (s16) = 0  (bytes 6..7)
    // phase  (u16) = 0  (bytes 8..9)
    // period (u16) in ms
    buf[10] = period_ms & 0xFF;
    buf[11] = (period_ms >> 8) & 0xFF;
    // waveform type
    buf[12] = waveform_type;
    // byte 14 effect_type stays 0
    buf[15] = 0x4F;                 // timing start
    buf[16] = 0xFF; buf[17] = 0xFF; // duration infinite
    buf[23] = 0xFF; buf[24] = 0xFF; // end marker

    return (*g_usb_iface)->WritePipe(g_usb_iface, g_out_pipe, buf, 64);
}

int thrustmaster_ff_sine(uint8_t effect_id, uint16_t magnitude, uint16_t period_ms) {
    // Waveform type 0x02 = sine (per Linux driver convention)
    int kr = ff_periodic_inner(effect_id, 0x02, magnitude, period_ms);
    if (kr == 0) {
        thrustmaster_ff_play(effect_id);
    }
    return kr;
}

int thrustmaster_ff_play(uint8_t effect_id) {
    if (!g_usb_iface || !g_out_pipe) return -1;

    // Play packet: header [0, id, 0x89], code=0x41, count=0 (infinite)
    uint8_t buf[64];
    memset(buf, 0, 64);
    buf[0] = 0x60;
    buf[1] = 0x00;
    buf[2] = effect_id;
    buf[3] = 0x89;  // play/stop command
    buf[4] = 0x41;  // play with count
    buf[5] = 0x00; buf[6] = 0x00;  // count = 0 (infinite)

    return (*g_usb_iface)->WritePipe(g_usb_iface, g_out_pipe, buf, 64);
}

int thrustmaster_ff_stop(uint8_t effect_id) {
    if (!g_usb_iface || !g_out_pipe) return -1;

    uint8_t buf[64];
    memset(buf, 0, 64);
    buf[0] = 0x60;
    buf[1] = 0x00;
    buf[2] = effect_id;
    buf[3] = 0x89;  // play/stop command
    buf[4] = 0x00;  // stop

    return (*g_usb_iface)->WritePipe(g_usb_iface, g_out_pipe, buf, 64);
}

void thrustmaster_usb_stop(void) {
    if (g_usb_iface) {
        (*g_usb_iface)->USBInterfaceClose(g_usb_iface);
        (*g_usb_iface)->Release(g_usb_iface);
        g_usb_iface = NULL;
    }
    if (g_usb_dev) {
        // Release capture — let HID driver reclaim
        (*g_usb_dev)->USBDeviceReEnumerate(g_usb_dev, kUSBReEnumerateReleaseDeviceMask);
        (*g_usb_dev)->USBDeviceClose(g_usb_dev);
        (*g_usb_dev)->Release(g_usb_dev);
        g_usb_dev = NULL;
    }
    g_in_pipe = 0;
    g_out_pipe = 0;
    g_report_callback = NULL;
    DBG("[USB-IO] Stopped, device released to system\n");
}

int thrustmaster_set_range_live(uint16_t range_degrees) {
    if (!g_usb_iface || !g_out_pipe) return -1;
    if (range_degrees < 40) range_degrees = 40;
    if (range_degrees > 1080) range_degrees = 1080;
    uint16_t scaled = (uint16_t)(range_degrees * 0x3C);
    uint8_t buf[64];
    memset(buf, 0, 64);
    buf[0] = 0x60; buf[1] = 0x08; buf[2] = 0x11;
    buf[3] = (uint8_t)(scaled & 0xFF);
    buf[4] = (uint8_t)(scaled >> 8);
    IOReturn kr = (*g_usb_iface)->WritePipe(g_usb_iface, g_out_pipe, buf, 64);
    DBG("[FF-USB] Live range=%u° (%s)\n", range_degrees,
           kr == KERN_SUCCESS ? "OK" : "FAIL");
    return kr == KERN_SUCCESS ? 0 : -2;
}

int thrustmaster_set_gain_live(uint16_t gain) {
    if (!g_usb_iface || !g_out_pipe) return -1;
    uint8_t buf[64];
    memset(buf, 0, 64);
    buf[0] = 0x60; buf[1] = 0x02; buf[2] = (uint8_t)(gain >> 8);
    IOReturn kr = (*g_usb_iface)->WritePipe(g_usb_iface, g_out_pipe, buf, 64);
    DBG("[FF-USB] Live gain=%u (%s)\n", gain,
           kr == KERN_SUCCESS ? "OK" : "FAIL");
    return kr == KERN_SUCCESS ? 0 : -2;
}
