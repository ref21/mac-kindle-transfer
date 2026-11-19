#include <libmtp.h>

// Every function below touches the libmtp device and must be called on the USB
// queue only, except the four marked "any thread", which use atomics only.

#define KD_CONNECT_OK 0
#define KD_CONNECT_NO_DEVICE 1   // no Kindle detected
#define KD_CONNECT_BUSY 2        // a Kindle was found but could not be opened
#define KD_CONNECT_STORAGE 3     // opened, but its storage is unavailable
int kd_connect(void);
void kd_disconnect(void);
LIBMTP_mtpdevice_t *kd_device(void);
// 1 if the device answers a storage query, else 0.
int kd_alive(void);
// USB vendor/product id of the connected Kindle (0 when not connected).
void kd_device_ids(uint16_t *vendor, uint16_t *product);
void kd_dump_device_info(void);

// First (oldest) entry of libmtp's error stack, else the shim's own message.
const char *kd_error(void);
// 1 if the error stack holds a USB-layer error or a PTP I/O (02ff) or timeout (02fa) error.
int kd_last_error_is_transport(void);

void kd_reset_transfer(void);   // any thread: clears cancel, progress and kd_cancel_at
void kd_cancel(void);           // any thread
int kd_cancelled(void);         // any thread
double kd_progress(void);       // any thread
// Test hook for --smoke-test: cancel the transfer once it reaches this fraction (0 = off).
void kd_cancel_at(double fraction);

// Sends a file. Never deletes anything. Returns libmtp's status (0 = success) and
// reports the item id libmtp left in its file struct and whether the progress
// callback ran (the data phase started, so the device had created the object).
// Parent 0 means the storage root.
int kd_upload(const char *path, const char *name, uint32_t parent, uint32_t storage, uint64_t size,
              uint32_t *item_id, int *data_phase);
// Returns the new folder's id, or 0 on failure. Parent 0 means the storage root.
uint32_t kd_create_folder(const char *name, uint32_t parent, uint32_t storage);
int kd_download(uint32_t id, const char *path);
