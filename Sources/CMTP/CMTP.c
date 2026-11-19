#include "CMTP.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// DEVICE_FLAG_FORCE_RESET_ON_CLOSE from libmtp's private device-flags.h.
#define KD_FLAG_FORCE_RESET_ON_CLOSE 0x10000000U

// USB queue only.
static LIBMTP_mtpdevice_t *device;
static uint16_t vendor_id, product_id;
static char message[512];
// Any thread.
static _Atomic int cancelled;
static _Atomic int data_phase;
static _Atomic double fraction;
static _Atomic double cancel_at;

LIBMTP_mtpdevice_t *kd_device(void) { return device; }
void kd_reset_transfer(void) { atomic_store(&cancelled, 0); atomic_store(&fraction, 0); atomic_store(&cancel_at, 0); }
void kd_cancel(void) { atomic_store(&cancelled, 1); }
int kd_cancelled(void) { return atomic_load(&cancelled); }
double kd_progress(void) { return atomic_load(&fraction); }
void kd_cancel_at(double at) { atomic_store(&cancel_at, at); }

// libmtp calls this only during the data phase of a transfer. For uploads that is
// after the device has created the object (libmtp.c, LIBMTP_Send_File_From_File_Descriptor:
// callback_active is set only once send_file_object_info() has succeeded).
static int progress(uint64_t sent, uint64_t total, const void *unused) {
    (void)unused;
    double done = total ? (double)sent / total : 0;
    atomic_store(&fraction, done);
    atomic_store(&data_phase, 1);
    double at = atomic_load(&cancel_at);
    if (at > 0 && done >= at) atomic_store(&cancelled, 1);
    return atomic_load(&cancelled);
}

const char *kd_error(void) {
    if (device) {
        LIBMTP_error_t *error = LIBMTP_Get_Errorstack(device);
        if (error && error->error_text) return error->error_text;
    }
    return message[0] ? message : "The Kindle could not complete the operation. Reconnect it and try again.";
}

int kd_last_error_is_transport(void) {
    if (!device) return 0;
    for (LIBMTP_error_t *error = LIBMTP_Get_Errorstack(device); error; error = error->next) {
        if (error->errornumber == LIBMTP_ERROR_USB_LAYER) return 1;
        // libmtp formats PTP errors as "PTP Layer error %04x: ..." (add_ptp_error_to_errorstack).
        unsigned code = 0;
        if (error->errornumber == LIBMTP_ERROR_PTP_LAYER && error->error_text &&
            sscanf(error->error_text, "PTP Layer error %4x", &code) == 1 &&
            (code == 0x02FF || code == 0x02FA)) return 1;   // PTP_ERROR_IO, PTP_ERROR_TIMEOUT
    }
    return 0;
}

int kd_connect(void) {
    static int initialised;
    if (device) return KD_CONNECT_OK;
    if (!initialised) { LIBMTP_Init(); initialised = 1; }
    LIBMTP_raw_device_t *raw = NULL; int count = 0, kindles = 0;
    LIBMTP_Detect_Raw_Devices(&raw, &count);
    for (int i = 0; i < count; i++) {
        if (raw[i].device_entry.vendor_id != 0x1949) continue;
        kindles++;
        // libmtp's table gives the Kindle e-reader id 1949:9981 the Android bug flags,
        // which include DEVICE_FLAG_FORCE_RESET_ON_CLOSE (device-flags.h): every
        // LIBMTP_Release_Device then sends a USB reset (libusb1-glue.c, close_usb), and
        // the Kindle treats that as an eject and leaves USB until it is replugged. The
        // flags are copied from this entry when the device is opened. (libmtp re-adds the
        // Android flags only for devices reporting the "android.com" MTP extension, which
        // Kindle e-readers do not; --dump prints the flags in effect.)
        raw[i].device_entry.device_flags &= ~KD_FLAG_FORCE_RESET_ON_CLOSE;
        device = LIBMTP_Open_Raw_Device_Uncached(&raw[i]);
        if (device) { vendor_id = raw[i].device_entry.vendor_id; product_id = raw[i].device_entry.product_id; break; }
    }
    free(raw);
    if (!device && !kindles) {
        strlcpy(message, "No Kindle was detected. Use a data-capable USB cable, wake the Kindle, and make sure it shows that it is connected for file transfer. If Send to Kindle, Calibre or another MTP app is open, quit it and try again.", sizeof message);
        return KD_CONNECT_NO_DEVICE;
    }
    if (!device) {
        strlcpy(message, "A Kindle was found but could not be opened. Quit other apps that may be using it (Send to Kindle, Calibre, OpenMTP, Android File Transfer, Preview, Image Capture) and try again. If it still fails, quit and reopen Kindle Drive.", sizeof message);
        return KD_CONNECT_BUSY;
    }
    // LIBMTP_Get_Storage returns 1 (not an error) on devices without GetStorageInfo.
    if (LIBMTP_Get_Storage(device, 0) < 0 || !device->storage) {
        strlcpy(message, "The Kindle connected but its storage is unavailable. Reconnect and try again.", sizeof message);
        kd_disconnect();
        return KD_CONNECT_STORAGE;
    }
    message[0] = 0;
    return KD_CONNECT_OK;
}

void kd_disconnect(void) {
    if (device) LIBMTP_Release_Device(device);
    device = NULL; vendor_id = 0; product_id = 0;
}

int kd_alive(void) { return device && LIBMTP_Get_Storage(device, 0) >= 0; }
void kd_device_ids(uint16_t *vendor, uint16_t *product) { *vendor = vendor_id; *product = product_id; }
void kd_dump_device_info(void) { if (device) LIBMTP_Dump_Device_Info(device); }

int kd_upload(const char *path, const char *name, uint32_t parent, uint32_t storage, uint64_t size,
              uint32_t *item_id, int *in_data_phase) {
    *item_id = 0; *in_data_phase = 0;
    if (!device) return -1;
    LIBMTP_file_t *file = LIBMTP_new_file_t();
    file->filename = strdup(name);   // freed by LIBMTP_destroy_file_t
    // Root is 0xFFFFFFFF for uploads: libmtp makes this conversion itself only on its
    // SendObjectPropList path; on the SendObjectInfo path 0 would mean "device chooses".
    file->parent_id = parent ? parent : 0xFFFFFFFF;
    file->storage_id = storage;
    file->filesize = size;
    file->filetype = LIBMTP_FILETYPE_UNKNOWN;
    atomic_store(&data_phase, 0);
    int status = LIBMTP_Send_File_From_File(device, path, file, progress, NULL);
    // After a failure item_id is NOT proof that an object was created: libmtp can leave
    // the object-format code 0x3000 in it. The caller decides what, if anything, to remove.
    *item_id = file->item_id;
    *in_data_phase = atomic_load(&data_phase);
    LIBMTP_destroy_file_t(file);
    return status;
}

uint32_t kd_create_folder(const char *name, uint32_t parent, uint32_t storage) {
    if (!device) return 0;
    char *copy = strdup(name);   // libmtp may edit the name in place
    if (!copy) return 0;
    // Parent 0 (root) is passed unchanged: the tested Kindle accepts it and libmtp's own
    // newfolder example documents 0 for the root.
    uint32_t id = LIBMTP_Create_Folder(device, copy, parent, storage);
    free(copy);
    return id;
}

int kd_download(uint32_t id, const char *path) {
    if (!device) return -1;
    return LIBMTP_Get_File_To_File(device, id, path, progress, NULL);
}
