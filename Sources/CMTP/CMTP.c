#include "CMTP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
static LIBMTP_mtpdevice_t *device;
static _Atomic int cancelled;
static _Atomic double fraction;
static char message[2048];
LIBMTP_mtpdevice_t *kd_device(void) { return device; }
void kd_begin(void) { atomic_store(&cancelled, 0); atomic_store(&fraction, 0); if(device) LIBMTP_Clear_Errorstack(device); }
void kd_cancel(void) { atomic_store(&cancelled, 1); }
int kd_cancelled(void) { return atomic_load(&cancelled); }
double kd_progress(void) { return atomic_load(&fraction); }
static int progress(uint64_t sent, uint64_t total, const void *unused) {
    (void)unused; atomic_store(&fraction, total ? (double)sent / total : 0); return atomic_load(&cancelled);
}
const char *kd_error(void) {
    if (device) {
        LIBMTP_error_t *error = LIBMTP_Get_Errorstack(device);
        if (error && error->error_text) return error->error_text;
    }
    return message[0] ? message : "The Kindle could not complete the operation. Reconnect it and try again.";
}
int kd_connect(void) {
    if(device) return 0;
    LIBMTP_Init();
    LIBMTP_raw_device_t *raw = NULL; int count = 0;
    LIBMTP_Detect_Raw_Devices(&raw, &count);
    for (int i=0; i<count; i++) {
        if(raw[i].device_entry.vendor_id != 0x1949) continue;
        device = LIBMTP_Open_Raw_Device_Uncached(&raw[i]);
        if(device) break;
    }
    free(raw);
    if(!device) { strcpy(message, "No available Kindle found. Connect a data-capable USB cable, enable USB file transfer on the Kindle, and close Calibre, Send to Kindle, or other MTP apps."); return -1; }
    if(LIBMTP_Get_Storage(device, 0) != 0 || !device->storage) {
        strcpy(message,"The Kindle connected but its storage is unavailable. Reconnect and try again.");
        LIBMTP_Release_Device(device); device=NULL; return -1;
    }
    message[0]=0; return 0;
}
void kd_disconnect(void) { if(device) LIBMTP_Release_Device(device); device=NULL; }
int kd_upload(const char *path, const char *name, uint32_t parent, uint32_t storage, uint64_t size, uint32_t *result) {
    if(!device) return -1;
    LIBMTP_file_t *file=LIBMTP_new_file_t();
    file->filename=strdup(name); file->parent_id=parent; file->storage_id=storage;
    file->filesize=size; file->filetype=LIBMTP_FILETYPE_UNKNOWN;
    int status=LIBMTP_Send_File_From_File(device,path,file,progress,NULL);
    *result=file->item_id;
    // Remove only an incomplete object created by this transfer.
    if(status && file->item_id) LIBMTP_Delete_Object(device,file->item_id);
    LIBMTP_destroy_file_t(file); return status;
}
int kd_download(uint32_t id, const char *path) {
    if(!device) return -1;
    return LIBMTP_Get_File_To_File(device,id,path,progress,NULL);
}
