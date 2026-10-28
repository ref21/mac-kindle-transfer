#include <libmtp.h>
int kd_connect(void);
void kd_disconnect(void);
LIBMTP_mtpdevice_t *kd_device(void);
const char *kd_error(void);
void kd_begin(void);
void kd_cancel(void);
int kd_cancelled(void);
double kd_progress(void);
int kd_upload(const char *path, const char *name, uint32_t parent, uint32_t storage, uint64_t size, uint32_t *result);
int kd_download(uint32_t id, const char *path);
