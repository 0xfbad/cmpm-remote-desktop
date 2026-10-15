#define _GNU_SOURCE
#include <errno.h>
#include <linux/capability.h>
#include <linux/filter.h>
#include <linux/magic.h>
#include <linux/seccomp.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <poll.h>
#include <sys/syscall.h>
#include "disk-setup.h"
#include "inotify-broker.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "guest-filter.h"

static volatile sig_atomic_t active_child = 0;
static int trusted_proc = -1;

static void forward_signal(int signal_number) {
    if (active_child > 0) kill(active_child, signal_number);
}

static void fail(const char *what) {
    fprintf(stderr, "launcher %s errno %d %s\n", what, errno, strerror(errno));
    exit(80);
}

static void put(const char *path, const char *value) {
    int fd = open(path, O_WRONLY | O_TRUNC | O_CREAT, 0600);
    if (fd < 0 || write(fd, value, strlen(value)) != (ssize_t)strlen(value)) fail(path);
    close(fd);
}

static void one(int fd) {
    char ch;
    if (read(fd, &ch, 1) != 1) fail("private handshake");
}

static void go(int fd) {
    if (write(fd, "1", 1) != 1) fail("private handshake write");
}

static unsigned long long starttime_at(int directory) {
    char data[8192];
    int fd = openat(directory, "stat", O_RDONLY);
    if (fd < 0) fail("target stat");
    ssize_t n = read(fd, data, sizeof(data) - 1);
    close(fd);
    if (n < 0) fail("target stat read");
    data[n] = 0;
    char *field = strrchr(data, ')');
    if (!field) fail("target stat format");
    field += 2;
    for (int i = 3; i < 22; i++) {
        field = strchr(field, ' ');
        if (!field) fail("target stat field");
        field++;
    }
    return strtoull(field, NULL, 10);
}

static int target_directory(pid_t pid) {
    char path[128];
    snprintf(path, sizeof(path), "/proc/%d", pid);
    int fd = open(path, O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) fail(path);
    return fd;
}

static int open_target(int directory, const char *tail) {
    int fd = openat(directory, tail, O_RDONLY | O_CLOEXEC);
    if (fd < 0) fail(tail);
    return fd;
}

static int finish(pid_t pid) {
    int status;
    active_child = pid;
    pid_t waited;
    do waited = waitpid(pid, &status, 0); while (waited < 0 && errno == EINTR);
    active_child = 0;
    if (waited < 0) fail("wait");
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 128 + WTERMSIG(status);
}

static void guest_policy(void) {
    struct sock_fprog program = {
        .len = sizeof(guest_filter) / sizeof(guest_filter[0]),
        .filter = (struct sock_filter *)guest_filter,
    };
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program)) fail("guest seccomp");
    struct __user_cap_header_struct header = {.version = _LINUX_CAPABILITY_VERSION_3, .pid = 0};
    struct __user_cap_data_struct current[2] = {0};
    if (syscall(SYS_capget, &header, &current)) fail("guest capability read");
    unsigned long long permitted = ((unsigned long long)current[1].permitted << 32) | current[0].permitted;
    const unsigned long long baseline = (1ULL << CAP_AUDIT_WRITE) | (1ULL << CAP_CHOWN) | (1ULL << CAP_DAC_OVERRIDE) | (1ULL << CAP_FOWNER) | (1ULL << CAP_KILL) | (1ULL << CAP_NET_BIND_SERVICE) | (1ULL << CAP_NET_RAW) | (1ULL << CAP_SETGID) | (1ULL << CAP_SETUID) | (1ULL << CAP_SYS_CHROOT);
    unsigned long long allowed = baseline & permitted;
    for (int cap = 0; cap <= CAP_LAST_CAP; cap++) {
        if (!(allowed & (1ULL << cap)) && prctl(PR_CAPBSET_DROP, cap, 0, 0, 0)) fail("guest capability bound");
    }
    struct __user_cap_data_struct data[2] = {
        {.effective = allowed & 0xffffffff, .permitted = allowed & 0xffffffff, .inheritable = 0},
        {.effective = allowed >> 32, .permitted = allowed >> 32, .inheritable = 0},
    };
    if (syscall(SYS_capset, &header, &data)) fail("guest capability set");
    if (syscall(SYS_close_range, 3U, ~0U, 0)) fail("close foreign descriptors");
}

static void guest_apparmor(void) {
    const char *profile = getenv("WORKSPACE_GUEST_APPARMOR");
    if (profile) {
        if (strcmp(profile, "docker-default")) {
            errno = EINVAL;
            fail("guest apparmor profile");
        }
        int attribute = openat(trusted_proc, "self/attr/exec", O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
        if (attribute < 0) fail("guest apparmor proc attribute");
        const char *transition = "exec docker-default";
        if (write(attribute, transition, strlen(transition)) != (ssize_t)strlen(transition)) fail("guest apparmor transition");
        close(attribute);
    }
    close(trusted_proc);
    trusted_proc = -1;
}

static void protect_proc(void) {
    const char *paths[] = {"/proc/bus", "/proc/fs", "/proc/irq", "/proc/sys", "/proc/sysrq-trigger"};
    for (unsigned int i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (access(paths[i], F_OK)) continue;
        if (mount(paths[i], paths[i], NULL, MS_BIND, NULL)) fail("protect proc bind");
        if (mount(NULL, paths[i], NULL, MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL)) fail("protect proc readonly");
    }
    const char *directories[] = {"/proc/asound", "/proc/acpi", "/proc/scsi"};
    for (unsigned int i = 0; i < sizeof(directories) / sizeof(directories[0]); i++) {
        if (access(directories[i], F_OK)) continue;
        if (mount("tmpfs", directories[i], "tmpfs", MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC, "size=4k,mode=000")) fail("mask proc directory");
    }
    const char *masked[] = {"/proc/interrupts", "/proc/kcore", "/proc/keys", "/proc/latency_stats", "/proc/timer_list", "/proc/timer_stats", "/proc/sched_debug"};
    for (unsigned int i = 0; i < sizeof(masked) / sizeof(masked[0]); i++) {
        if (access(masked[i], F_OK)) continue;
        if (mount("/dev/null", masked[i], NULL, MS_BIND, NULL)) fail("mask proc file");
    }
}

static int enter(int argc, char **argv) {
    if (argc < 4) return 64;
    char generation[128];
    pid_t pid;
    unsigned long long expected;
    FILE *state = fopen("/state/guest", "r");
    if (!state || fscanf(state, "%127s %d %llu", generation, &pid, &expected) != 3) fail("state");
    fclose(state);
    if (strcmp(generation, argv[2])) return 75;
    int channel = open_inotify_broker(argv[2]);
    int directory = target_directory(pid);
    int process = syscall(SYS_pidfd_open, pid, 0);
    if (process < 0) fail("target process handle");
    if (starttime_at(directory) != expected) return 76;
    int mountfd = open_target(directory, "ns/mnt");
    int pidfd = open_target(directory, "ns/pid");
    int root = open_target(directory, "root");
    if (starttime_at(directory) != expected) return 76;
    close(directory);
    struct pollfd alive = {.fd = process, .events = POLLIN};
    if (poll(&alive, 1, 0) != 0) return 76;
    close(process);
    if (setns(pidfd, CLONE_NEWPID)) fail("enter guest pid");
    if (setns(mountfd, CLONE_NEWNS)) fail("enter guest mount");
    if (fchdir(root) || chroot(".") || chdir("/")) fail("enter guest root");
    close(mountfd);
    close(pidfd);
    close(root);
    pid_t child = fork();
    if (child < 0) fail("enter fork");
    if (!child) {
        install_inotify_notification(channel);
        guest_apparmor();
        guest_policy();
        execvp(argv[3], argv + 3);
        fail("enter exec");
    }
    close(channel);
    return finish(child);
}

static int initialize(int argc, char **argv) {
    if (argc < 4) return 64;
    const char *size = getenv("WORKSPACE_DISK_BYTES");
    unsigned long long bytes = size ? strtoull(size, NULL, 10) : 20ULL * 1024 * 1024 * 1024;
    int loop = prepare_disk(argv[2], bytes);
    pid_t broker = start_inotify_broker(argv[2]);
    int channel = open_inotify_broker(argv[2]);
    int targetpipe[2], guestgo[2];
    if (pipe2(targetpipe, O_CLOEXEC) || pipe2(guestgo, O_CLOEXEC)) fail("pipes");
    prctl(PR_SET_DUMPABLE, 0);
    pid_t supervisor = fork();
    if (supervisor < 0) fail("supervisor fork");
    if (!supervisor) {
        active_child = 0;
        close(targetpipe[0]);
        close(guestgo[1]);
        enter_disk_root();
        close(loop);
        if (unshare(CLONE_NEWPID)) fail("guest pid namespace");
        pid_t guest = fork();
        if (guest < 0) fail("guest fork");
        if (!guest) {
            active_child = 0;
            close(targetpipe[1]);
            if (mount("proc", "/proc", "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV, NULL)) fail("guest proc");
            if (mount("tmpfs", "/state", "tmpfs", MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC, "size=4k")) fail("mask state");
            protect_proc();
            one(guestgo[0]);
            close(guestgo[0]);
            install_inotify_notification(channel);
            guest_apparmor();
            guest_policy();
            execvp(argv[3], argv + 3);
            fail("guest exec");
        }
        close(channel);
        close(guestgo[0]);
        if (write(targetpipe[1], &guest, sizeof(guest)) != sizeof(guest)) fail("guest pid write");
        close(targetpipe[1]);
        prctl(PR_SET_DUMPABLE, 0);
        return finish(guest);
    }
    close(channel);
    close(targetpipe[1]);
    close(guestgo[0]);
    pid_t target;
    if (read(targetpipe[0], &target, sizeof(target)) != sizeof(target)) fail("guest pid read");
    close(targetpipe[0]);
    char state[256];
    int directory = target_directory(target);
    snprintf(state, sizeof(state), "%s %d %llu\n", argv[2], target, starttime_at(directory));
    close(directory);
    put("/state/guest", state);
    go(guestgo[1]);
    close(guestgo[1]);
    printf("READY %d %d\n", supervisor, target);
    fflush(stdout);
    int status = finish(supervisor);
    kill(broker, SIGKILL);
    finish(broker);
    close(loop);
    return status;
}

int main(int argc, char **argv) {
    trusted_proc = open("/proc", O_PATH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (trusted_proc < 0) fail("trusted proc directory");
    struct statfs filesystem;
    if (fstatfs(trusted_proc, &filesystem) || filesystem.f_type != PROC_SUPER_MAGIC) fail("trusted proc filesystem");
    struct sigaction action = {.sa_handler = forward_signal};
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGHUP, &action, NULL);
    if (argc > 1 && !strcmp(argv[1], "init")) return initialize(argc, argv);
    if (argc > 1 && !strcmp(argv[1], "enter")) return enter(argc, argv);
    return 64;
}
