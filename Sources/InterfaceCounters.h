#include <stdint.h>
int dp_interface_counters(const char *name, uint64_t *down, uint64_t *up);
int dp_process_identity(int pid, char *path, int capacity, uint32_t *uid, int *parent, uint64_t *started);
int dp_process_command(int pid, char *command, int capacity);
int dp_background_transfer_pids(int *pids, int capacity);
