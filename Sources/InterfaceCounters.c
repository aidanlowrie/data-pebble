#include "InterfaceCounters.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_mib.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>

int dp_interface_counters(const char *name, uint64_t *down, uint64_t *up) {
    unsigned int index = if_nametoindex(name);
    if (!index) return -1;
    int mib[] = { CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, (int)index, IFDATA_GENERAL };
    struct ifmibdata data = {0};
    size_t size = sizeof(data);
    if (sysctl(mib, 6, &data, &size, NULL, 0) || size != sizeof(data)) return -1;
    *down = data.ifmd_data.ifi_ibytes;
    *up = data.ifmd_data.ifi_obytes;
    return 0;
}

static int dp_bsd_info(int pid, struct proc_bsdinfo *info) {
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof(*info)) == (int)sizeof(*info)) return 0;
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc data = {0}; size_t size = sizeof(data);
    if (sysctl(mib, 4, &data, &size, NULL, 0) || size != sizeof(data)) return -1;
    info->pbi_uid = data.kp_eproc.e_ucred.cr_uid;
    info->pbi_ppid = (uint32_t)data.kp_eproc.e_ppid;
    info->pbi_start_tvsec = (uint64_t)data.kp_proc.p_starttime.tv_sec;
    strlcpy(info->pbi_comm, data.kp_proc.p_comm, sizeof(info->pbi_comm));
    return 0;
}

int dp_process_identity(int pid, char *path, int capacity, uint32_t *uid, int *parent, uint64_t *started) {
    struct proc_bsdinfo info = {0};
    if (capacity <= 0 || dp_bsd_info(pid, &info)) return -1;
    // Protected system services may expose their owner but not executable path.
    if (proc_pidpath(pid, path, (uint32_t)capacity) <= 0) path[0] = 0;
    *uid = info.pbi_uid; *parent = (int)info.pbi_ppid; *started = info.pbi_start_tvsec;
    return 0;
}

// Return argv only, never the environment that follows it in KERN_PROCARGS2.
int dp_process_command(int pid, char *command, int capacity) {
    if (capacity <= 0) return -1;
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) || size < sizeof(int)) return -1;
    char *data = malloc(size);
    if (!data) return -1;
    if (sysctl(mib, 3, data, &size, NULL, 0)) { free(data); return -1; }
    int argc = 0; memcpy(&argc, data, sizeof(argc));
    size_t pos = sizeof(argc), used = 0;
    while (pos < size && data[pos]) pos++;
    while (pos < size && !data[pos]) pos++;
    for (int arg = 0; arg < argc && pos < size; arg++) {
        if (used && used + 1 < (size_t)capacity) command[used++] = '\n';
        while (pos < size && data[pos]) {
            if (used + 1 < (size_t)capacity) command[used++] = data[pos];
            pos++;
        }
        pos++;
    }
    command[used] = 0;
    free(data);
    return 0;
}

int dp_background_transfer_pids(int *pids, int capacity) {
    int size = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (size <= 0 || capacity <= 0) return 0;
    size += 32 * (int)sizeof(int);
    int *all = malloc((size_t)size);
    if (!all) return 0;
    int count = proc_listpids(PROC_ALL_PIDS, 0, all, size) / (int)sizeof(int), found = 0;
    for (int i = 0; i < count && found < capacity; i++) {
        struct proc_bsdinfo info = {0};
        if (dp_bsd_info(all[i], &info) == 0 &&
            strcmp(info.pbi_comm, "nsurlsessiond") == 0) pids[found++] = all[i];
    }
    free(all);
    return found;
}
