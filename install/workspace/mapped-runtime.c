#define _GNU_SOURCE
#include "mapped-runtime.h"
#include "disk-setup.h"
#include "mapped-network.h"
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/capability.h>
#include <linux/magic.h>
#include <linux/nsfs.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/un.h>
#include <sys/vfs.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define DISK_BYTES (20ULL * 1024 * 1024 * 1024)
#define ENTRY_SOCKET "/state/mapped-entry"
#define SERVER_STATE "/state/mapped-server"

struct entry {
    char generation[128];
    pid_t keeper;
    unsigned long long starttime;
    struct mapped_identity identity;
    struct stat user, mount, network, root;
};

struct packet {
    uint32_t stage;
    struct entry entry;
};

static struct {
    pid_t keeper, fuse;
    int loop, listener, channel, handles[5], devices, socket_created, server_created;
    struct mapped_network network;
    struct entry entry;
} owned = {.loop = -1,
           .listener = -1,
           .channel = -1,
           .handles = {-1, -1, -1, -1, -1},
           .network = {.dns_fd = -1}};
static volatile sig_atomic_t stop_signal;
static int supervisor_process = 1;

static void die(const char *what) {
    fprintf(stderr, "mapped %s errno %d %s\n", what, errno, strerror(errno));
    exit(80);
}

static void stopped(int signal_number) { stop_signal = signal_number; }

static unsigned long long monotonic_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value))
        die("clock");
    return (unsigned long long)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static int base_number(const char *value, unsigned long *number) {
    if (!value || !*value)
        return -1;
    for (const char *at = value; *at; at++)
        if (*at < '0' || *at > '9')
            return -1;
    errno = 0;
    char *end;
    *number = strtoul(value, &end, 10);
    if (errno || *end || *number < 2147483648UL || *number > 4294836224UL || *number % 65536UL)
        return -1;
    return 0;
}

int mapped_inputs(const char *generation, const char *uid, const char *gid, const char *bytes,
                  struct mapped_identity *identity) {
    if (!generation || !*generation || strlen(generation) > 127 || !identity)
        return -1;
    for (const unsigned char *at = (const unsigned char *)generation; *at; at++) {
        if (!((*at >= 'a' && *at <= 'z') || (*at >= 'A' && *at <= 'Z') ||
              (*at >= '0' && *at <= '9') || *at == '-' || *at == '_'))
            return -1;
    }
    unsigned long user, group;
    if (base_number(uid, &user) || base_number(gid, &group))
        return -1;
    if (bytes && strcmp(bytes, "21474836480"))
        return -1;
    identity->uid = (uid_t)user;
    identity->gid = (gid_t)group;
    return 0;
}

static int same(const struct stat *left, const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

static void directory(const char *path, mode_t mode) {
    if (mkdir(path, mode) && errno != EEXIST)
        die(path);
    struct stat info;
    if (lstat(path, &info) || !S_ISDIR(info.st_mode) || info.st_uid || info.st_gid)
        die("directory identity");
    if (chmod(path, mode))
        die("directory mode");
}

static void mount_at(const char *source, const char *target, const char *type, unsigned long flags,
                     const char *data) {
    if (mount(source, target, type, flags, data))
        die(target);
}

static void write_all(int fd, const void *data, size_t size) {
    for (size_t offset = 0; offset < size;) {
        ssize_t count = write(fd, (const char *)data + offset, size - offset);
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            die("write");
        offset += (size_t)count;
    }
}

static unsigned long long starttime(pid_t pid) {
    char path[64], data[8192];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
        die("keeper stat");
    ssize_t count = read(fd, data, sizeof(data) - 1);
    close(fd);
    if (count <= 0 || count == (ssize_t)sizeof(data) - 1)
        die("keeper stat read");
    data[count] = 0;
    char *field = strrchr(data, ')');
    if (!field)
        die("keeper stat format");
    field += 2;
    for (int i = 3; i < 22; i++) {
        field = strchr(field, ' ');
        if (!field)
            die("keeper stat field");
        field++;
    }
    return strtoull(field, NULL, 10);
}

static int receive(int socket, struct packet *packet, int *fds, size_t expected) {
    char control[CMSG_SPACE(8 * sizeof(int))];
    memset(control, 0, sizeof(control));
    struct iovec vector = {.iov_base = packet, .iov_len = sizeof(*packet)};
    struct msghdr message = {.msg_iov = &vector,
                             .msg_iovlen = 1,
                             .msg_control = control,
                             .msg_controllen = sizeof(control)};
    ssize_t count = recvmsg(socket, &message, MSG_CMSG_CLOEXEC);
    size_t total = 0;
    int invalid = count != sizeof(*packet) || (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC));
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header;
         header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
            header->cmsg_len < CMSG_LEN(0) || (header->cmsg_len - CMSG_LEN(0)) % sizeof(int)) {
            invalid = 1;
            continue;
        }
        size_t length = (header->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        int *received = (int *)CMSG_DATA(header);
        for (size_t i = 0; i < length; i++) {
            if (total < expected)
                fds[total] = received[i];
            else
                close(received[i]);
            total++;
        }
    }
    if (!invalid && total == expected)
        return 0;
    for (size_t i = 0; i < total && i < expected; i++) {
        close(fds[i]);
        fds[i] = -1;
    }
    errno = EPROTO;
    return -1;
}

static int send_packet(int socket, const struct packet *packet, const int *fds, size_t count) {
    if (count > 5) {
        errno = EINVAL;
        return -1;
    }
    char control[CMSG_SPACE(5 * sizeof(int))];
    struct iovec vector = {.iov_base = (void *)packet, .iov_len = sizeof(*packet)};
    struct msghdr message = {.msg_iov = &vector, .msg_iovlen = 1};
    if (count) {
        memset(control, 0, sizeof(control));
        message.msg_control = control;
        message.msg_controllen = CMSG_SPACE(count * sizeof(int));
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        header->cmsg_level = SOL_SOCKET;
        header->cmsg_type = SCM_RIGHTS;
        header->cmsg_len = CMSG_LEN(count * sizeof(int));
        memcpy(CMSG_DATA(header), fds, count * sizeof(int));
    }
    return sendmsg(socket, &message, MSG_NOSIGNAL) == sizeof(*packet) ? 0 : -1;
}

static void handshake(int socket, unsigned stage) {
    struct packet packet;
    if (receive(socket, &packet, NULL, 0) || packet.stage != stage)
        die("handshake");
}

static void signal_stage(int socket, unsigned stage) {
    struct packet packet = {.stage = stage};
    if (send_packet(socket, &packet, NULL, 0))
        die("handshake send");
}

static void terminate(pid_t *pid) {
    if (*pid <= 0)
        return;
    kill(*pid, SIGTERM);
    unsigned long long until = monotonic_ms() + 3500;
    int status;
    for (;;) {
        pid_t result = waitpid(*pid, &status, WNOHANG);
        if (result == *pid || (result < 0 && errno == ECHILD))
            break;
        if (monotonic_ms() >= until) {
            kill(*pid, SIGKILL);
            while (waitpid(*pid, &status, 0) < 0 && errno == EINTR) {
            }
            break;
        }
        struct timespec delay = {.tv_nsec = 10000000};
        nanosleep(&delay, NULL);
    }
    *pid = 0;
}

static void cleanup(void) {
    if (!supervisor_process)
        return;
    int saved = errno;
    if (owned.listener >= 0) {
        close(owned.listener);
    }
    if (owned.socket_created)
        unlink(ENTRY_SOCKET);
    if (owned.server_created)
        unlink(SERVER_STATE);
    if (owned.channel >= 0)
        close(owned.channel);
    for (unsigned i = 0; i < 5; i++)
        if (owned.handles[i] >= 0)
            close(owned.handles[i]);
    terminate(&owned.keeper);
    if (mapped_network_cleanup(&owned.network))
        fprintf(stderr, "mapped network cleanup errno %d\n", errno);
    terminate(&owned.fuse);
    if (owned.devices)
        umount2("/quota-runtime/devices", MNT_DETACH);
    umount2("/quota-runtime/base", MNT_DETACH);
    umount2("/quota-runtime/fs", MNT_DETACH);
    if (owned.loop >= 0)
        close(owned.loop);
    errno = saved;
}

static void store_identity(const struct mapped_identity *identity) {
    char value[128], data[128];
    int directory = open("/quota-store", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat directory_info;
    if (directory < 0 || fstat(directory, &directory_info) || directory_info.st_uid ||
        directory_info.st_gid || (directory_info.st_mode & 022))
        die("quota volume identity");
    close(directory);
    int length = snprintf(value, sizeof(value), "mapped1 %u %u %llu\n", identity->uid,
                          identity->gid, DISK_BYTES);
    struct stat info;
    int existing = !lstat("/quota-store/root.img", &info);
    if (!existing && errno != ENOENT)
        die("backing identity");
    int fd =
        open("/quota-store/identity", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd >= 0) {
        if (existing) {
            close(fd);
            unlink("/quota-store/identity");
            errno = EINVAL;
            die("backing missing mapped identity");
        }
        write_all(fd, value, (size_t)length);
        if (fsync(fd) || close(fd))
            die("identity sync");
        return;
    }
    if (errno != EEXIST)
        die("identity create");
    fd = open("/quota-store/identity", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0 || fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_nlink != 1 || info.st_uid ||
        info.st_gid || (info.st_mode & 0777) != 0600)
        die("identity metadata");
    ssize_t count = read(fd, data, sizeof(data));
    close(fd);
    if (count != length || memcmp(data, value, (size_t)length)) {
        errno = EINVAL;
        die("identity mismatch");
    }
}

static void devices(void) {
    directory("/quota-runtime/devices", 0755);
    mount_at("tmpfs", "/quota-runtime/devices", "tmpfs", MS_NOSUID | MS_NOEXEC,
             "size=64k,mode=755");
    owned.devices = 1;
    directory("/quota-runtime/devices/pts", 0755);
    directory("/quota-runtime/devices/shm", 01777);
    const char *names[] = {"null", "zero", "full", "random", "urandom", "tty"};
    const unsigned minors[] = {3, 5, 7, 8, 9, 0};
    for (unsigned i = 0; i < 6; i++) {
        char path[128];
        snprintf(path, sizeof(path), "/quota-runtime/devices/%s", names[i]);
        if (mknod(path, S_IFCHR | 0666, makedev(i == 5 ? 5 : 1, minors[i])) || chmod(path, 0666))
            die("device");
    }
    const char *links[] = {"ptmx", "fd", "stdin", "stdout", "stderr"};
    const char *targets[] = {"pts/ptmx", "/proc/self/fd", "/proc/self/fd/0", "/proc/self/fd/1",
                             "/proc/self/fd/2"};
    for (unsigned i = 0; i < 5; i++) {
        char path[128];
        snprintf(path, sizeof(path), "/quota-runtime/devices/%s", links[i]);
        if (symlink(targets[i], path))
            die("device link");
    }
}

static void state_volume(const struct mapped_identity *identity) {
    struct stat info;
    if (lstat("/var/lib/remote-desktop", &info) || !S_ISDIR(info.st_mode))
        die("account volume");
    if (info.st_uid == identity->uid && info.st_gid == identity->gid &&
        (info.st_mode & 0777) == 0700)
        return;
    if (info.st_uid || info.st_gid)
        die("account volume identity");
    int fd = open("/var/lib/remote-desktop", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
        die("account volume open");
    DIR *contents = fdopendir(dup(fd));
    if (!contents)
        die("account volume listing");
    struct dirent *item;
    errno = 0;
    while ((item = readdir(contents))) {
        if (strcmp(item->d_name, ".") && strcmp(item->d_name, ".."))
            die("foreign account volume");
    }
    if (errno || closedir(contents))
        die("account volume listing read");
    if (fchown(fd, identity->uid, identity->gid) || fchmod(fd, 0700))
        die("account volume ownership");
    close(fd);
}

static void copy_config(const char *name) {
    char source[128], target[256], data[65537];
    snprintf(source, sizeof(source), "/etc/%s", name);
    snprintf(target, sizeof(target), "/quota-runtime/root/etc/%s", name);
    int input = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    struct stat info;
    if (input < 0 || fstat(input, &info) || !S_ISREG(info.st_mode) || info.st_size > 65536)
        die("config input");
    ssize_t count = read(input, data, sizeof(data));
    close(input);
    if (count < 0 || count > 65536)
        die("config read");
    int output =
        open(target, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0644);
    if (output < 0 || fstat(output, &info) || !S_ISREG(info.st_mode) || info.st_uid || info.st_gid)
        die("config output");
    write_all(output, data, (size_t)count);
    if (fchmod(output, 0644))
        die("config mode");
    close(output);
}

static void resolver_config(const char *address) {
    int fd = open("/etc/resolv.conf", O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    struct stat info;
    if (fd < 0 || fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid || info.st_gid ||
        info.st_size > 65536)
        die("resolver destination");
    char data[65537], output[65537];
    ssize_t count = read(fd, data, sizeof(data) - 1);
    if (count < 0 || count != info.st_size)
        die("resolver read");
    size_t used = (size_t)snprintf(output, sizeof(output), "nameserver %s\n", address);
    for (size_t offset = 0; offset < (size_t)count;) {
        size_t end = offset;
        while (end < (size_t)count && data[end] != '\n')
            end++;
        if (end < (size_t)count)
            end++;
        size_t token = offset;
        while (token < end && (data[token] == ' ' || data[token] == '\t'))
            token++;
        int nameserver = end - token >= 10 && !memcmp(data + token, "nameserver", 10) &&
                         (end - token == 10 || data[token + 10] == ' ' ||
                          data[token + 10] == '\t' || data[token + 10] == '\n');
        if (!nameserver) {
            if (used + end - offset > 65536) {
                errno = E2BIG;
                die("resolver size");
            }
            memcpy(output + used, data + offset, end - offset);
            used += end - offset;
        }
        offset = end;
    }
    if (ftruncate(fd, 0) || lseek(fd, 0, SEEK_SET))
        die("resolver reset");
    write_all(fd, output, used);
    close(fd);
}

static void trusted_tool(const char *path) {
    struct stat info;
    if (stat(path, &info))
        die(path);
    if (!S_ISREG(info.st_mode) || info.st_uid || info.st_gid || (info.st_mode & 022)) {
        errno = EPERM;
        die(path);
    }
}

static void initial_apparmor(void (*apparmor)(void)) {
    const unsigned word = CAP_MAC_OVERRIDE / 32;
    const unsigned bit = 1U << (CAP_MAC_OVERRIDE % 32);
    const unsigned long long mac = 1ULL << CAP_MAC_OVERRIDE;
    struct __user_cap_header_struct header = {.version = _LINUX_CAPABILITY_VERSION_3};
    struct __user_cap_data_struct expected[2] = {0}, observed[2] = {0};
    unsigned long long bounding = 0, ambient = 0;
    if (syscall(SYS_capget, &header, expected))
        die("initial apparmor capabilities read");
    for (int cap = 0; cap <= CAP_LAST_CAP; cap++) {
        int bound = prctl(PR_CAPBSET_READ, cap, 0, 0, 0);
        int raised = prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_IS_SET, cap, 0, 0);
        if (bound < 0 || raised < 0)
            die("initial apparmor capability bounds read");
        if (bound)
            bounding |= 1ULL << cap;
        if (raised)
            ambient |= 1ULL << cap;
    }
    if (apparmor && getenv("WORKSPACE_GUEST_APPARMOR") &&
        (!(expected[word].effective & bit) || !(expected[word].permitted & bit))) {
        errno = EPERM;
        die("initial apparmor required capability");
    }
    if (apparmor)
        apparmor();
    if (prctl(PR_CAPBSET_DROP, CAP_MAC_OVERRIDE, 0, 0, 0) ||
        prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_LOWER, CAP_MAC_OVERRIDE, 0, 0))
        die("initial apparmor capability bounds drop");
    expected[word].effective &= ~bit;
    expected[word].permitted &= ~bit;
    expected[word].inheritable &= ~bit;
    if (syscall(SYS_capset, &header, expected) || syscall(SYS_capget, &header, observed))
        die("initial apparmor capability set");
    if (memcmp(expected, observed, sizeof(expected))) {
        errno = EPERM;
        die("initial apparmor capability identity");
    }
    bounding &= ~mac;
    ambient &= ~mac;
    for (int cap = 0; cap <= CAP_LAST_CAP; cap++) {
        int bound = prctl(PR_CAPBSET_READ, cap, 0, 0, 0);
        int raised = prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_IS_SET, cap, 0, 0);
        if (bound < 0 || raised < 0)
            die("initial apparmor capability bounds verify");
        if (bound != !!(bounding & (1ULL << cap)) ||
            raised != !!(ambient & (1ULL << cap))) {
            errno = EPERM;
            die("initial apparmor capability bounds identity");
        }
    }
}

static void fuse_policy(void) {
    const unsigned long long allowed = (1ULL << CAP_CHOWN) | (1ULL << CAP_DAC_OVERRIDE) |
                                       (1ULL << CAP_FOWNER) | (1ULL << CAP_MKNOD) |
                                       (1ULL << CAP_SETFCAP);
    struct __user_cap_header_struct header = {.version = _LINUX_CAPABILITY_VERSION_3};
    struct __user_cap_data_struct capabilities[2] = {0};
    if (syscall(SYS_capget, &header, capabilities))
        die("fuse capabilities read");
    unsigned long long current =
        ((unsigned long long)capabilities[1].permitted << 32) | capabilities[0].permitted;
    if ((current & allowed) != allowed) {
        errno = EPERM;
        die("fuse required capabilities");
    }
    for (int cap = 0; cap <= CAP_LAST_CAP; cap++) {
        if (!(allowed & (1ULL << cap)) && prctl(PR_CAPBSET_DROP, cap, 0, 0, 0))
            die("fuse capability bound");
    }
    capabilities[0] = (struct __user_cap_data_struct){.effective = allowed & 0xffffffff,
                                                      .permitted = allowed & 0xffffffff};
    capabilities[1] =
        (struct __user_cap_data_struct){.effective = allowed >> 32, .permitted = allowed >> 32};
    if (syscall(SYS_capset, &header, capabilities) ||
        prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) ||
        prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))
        die("fuse capability set");
}

static pid_t start_fuse(int fd) {
    trusted_tool("/usr/local/libexec/fuse-overlayfs");
    pid_t pid = fork();
    if (pid < 0)
        die("fuse fork");
    if (pid)
        return pid;
    supervisor_process = 0;
    if (fd != 3 && dup2(fd, 3) < 0)
        die("fuse descriptor");
    if (fcntl(3, F_SETFD, 0) || syscall(SYS_close_range, 4U, ~0U, 0))
        die("fuse descriptors");
    fuse_policy();
    char *const args[] = {"/usr/local/libexec/fuse-overlayfs",
                          "-f",
                          "-o",
                          "lowerdir=/quota-runtime/base,upperdir=/quota-runtime/fs/upper,workdir=/"
                          "quota-runtime/fs/work",
                          "/dev/fd/3",
                          NULL};
    char *const environment[] = {"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C", NULL};
    execve(args[0], args, environment);
    die("fuse exec");
    return 0;
}

static void map_file(pid_t keeper, const char *name, unsigned base) {
    char path[128], value[64];
    snprintf(path, sizeof(path), "/proc/%d/%s", keeper, name);
    snprintf(value, sizeof(value), "0 %u 65536\n", base);
    int fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
        die("mapping open");
    write_all(fd, value, strlen(value));
    close(fd);
}

static void root_directory(const char *path, mode_t mode) {
    if (mkdir(path, mode) && errno != EEXIST)
        die(path);
    struct stat info;
    if (lstat(path, &info) || !S_ISDIR(info.st_mode) || info.st_uid || info.st_gid)
        die("guest directory");
}

static int keeper(int channel, char **command, void (*protect)(void), void (*apparmor)(void),
                  void (*policy)(void)) {
    supervisor_process = 0;
    close(owned.channel);
    close(owned.loop);
    initial_apparmor(apparmor);
    if (prctl(PR_SET_KEEPCAPS, 1, 0, 0, 0))
        die("creator keep capabilities");
    if (setgroups(0, NULL) ||
        setresgid(owned.entry.identity.gid, owned.entry.identity.gid, owned.entry.identity.gid) ||
        setresuid(owned.entry.identity.uid, owned.entry.identity.uid, owned.entry.identity.uid))
        die("creator identity");
    const unsigned admin = 1U << CAP_SYS_ADMIN;
    struct __user_cap_header_struct header = {.version = _LINUX_CAPABILITY_VERSION_3};
    struct __user_cap_data_struct capabilities[2] = {{.effective = admin, .permitted = admin}, {0}};
    if (syscall(SYS_capset, &header, capabilities) ||
        prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) ||
        syscall(SYS_capget, &header, capabilities))
        die("creator capabilities");
    if (capabilities[0].effective != admin || capabilities[0].permitted != admin ||
        capabilities[0].inheritable || capabilities[1].effective || capabilities[1].permitted ||
        capabilities[1].inheritable) {
        errno = EPERM;
        die("creator capability identity");
    }
    if (unshare(CLONE_NEWUSER))
        die("user namespace");
    int keepcaps = prctl(PR_GET_KEEPCAPS, 0, 0, 0, 0);
    if (keepcaps < 0)
        die("user namespace keep capabilities");
    if (keepcaps) {
        errno = EPERM;
        die("user namespace keep capabilities reset");
    }
    signal_stage(channel, 0);
    handshake(channel, 1);
    if (setgroups(0, NULL))
        die("mapped setgroups");
    if (setresgid(0, 0, 0))
        die("mapped setresgid");
    if (setresuid(0, 0, 0))
        die("mapped setresuid");
    if (prctl(PR_SET_DUMPABLE, 0))
        die("mapped dumpable");
    if (unshare(CLONE_NEWNS | CLONE_NEWNET))
        die("mount network namespace");
    mount_at(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL);
    int fuse = open("/dev/fuse", O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fuse < 0)
        die("fuse device");
    char options[256];
    snprintf(options, sizeof(options),
             "fd=%d,rootmode=40000,user_id=0,group_id=0,allow_other,default_permissions", fuse);
    mount_at("fuse-overlayfs", "/quota-runtime/root", "fuse", 0, options);
    struct packet packet = {.stage = 2};
    if (send_packet(channel, &packet, &fuse, 1))
        die("fuse send");
    close(fuse);
    handshake(channel, 3);
    root_directory("/quota-runtime/root/dev", 0755);
    root_directory("/quota-runtime/root/proc", 0555);
    root_directory("/quota-runtime/root/state", 0700);
    root_directory("/quota-runtime/root/var/lib/remote-desktop", 0700);
    mount_at("/quota-runtime/devices", "/quota-runtime/root/dev", NULL, MS_BIND, NULL);
    mount_at("/dev/shm", "/quota-runtime/root/dev/shm", NULL, MS_BIND, NULL);
    mount_at("devpts", "/quota-runtime/root/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC,
             "newinstance,ptmxmode=0666,mode=0620,max=128");
    mount_at("/proc", "/quota-runtime/root/proc", NULL, MS_BIND | MS_REC, NULL);
    mount_at("tmpfs", "/quota-runtime/root/state", "tmpfs",
             MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC, "size=4k");
    mount_at("/var/lib/remote-desktop", "/quota-runtime/root/var/lib/remote-desktop", NULL, MS_BIND,
             NULL);
    copy_config("hosts");
    copy_config("hostname");
    copy_config("resolv.conf");
    const char *paths[] = {"/proc/self/ns/user", "/proc/self/ns/mnt", "/proc/self/ns/net",
                           "/quota-runtime/root"};
    int handles[4];
    for (unsigned i = 0; i < 4; i++) {
        handles[i] = open(paths[i], O_RDONLY | O_CLOEXEC);
        if (handles[i] < 0)
            die("keeper handle");
    }
    if (fstat(handles[3], &packet.entry.root))
        die("keeper root stat");
    if (!S_ISDIR(packet.entry.root.st_mode) || packet.entry.root.st_uid ||
        packet.entry.root.st_gid) {
        errno = EPERM;
        die("keeper root identity");
    }
    if (fchdir(handles[3]) || chroot(".") || chdir("/"))
        die("keeper root");
    protect();
    packet.stage = 4;
    if (send_packet(channel, &packet, handles, 4))
        die("keeper send");
    if (receive(channel, &packet, NULL, 0) || packet.stage != 5 || packet.entry.generation[15])
        die("network handshake");
    struct in_addr address;
    if (inet_pton(AF_INET, packet.entry.generation, &address) != 1)
        die("resolver address");
    resolver_config(packet.entry.generation);
    pid_t child = fork();
    if (child < 0)
        die("startup fork");
    if (!child) {
        if (prctl(PR_SET_PDEATHSIG, SIGTERM) || getppid() == 1)
            die("startup parent");
        if (fchdir(handles[3]) || chroot(".") || chdir("/"))
            die("startup root");
        policy();
        execvp(command[0], command);
        die("startup exec");
    }
    for (unsigned i = 0; i < 4; i++)
        close(handles[i]);
    int status;
    for (;;) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child)
            break;
        if (result < 0 && errno != EINTR)
            die("startup wait");
        struct pollfd control = {.fd = channel, .events = POLLIN};
        if (stop_signal || poll(&control, 1, 50) > 0) {
            terminate(&child);
            status = 0;
            break;
        }
    }
    close(channel);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static void namespace_check(int fd, int kind, const struct stat *expected, int userfd) {
    struct stat actual;
    if (ioctl(fd, NS_GET_NSTYPE) != kind || fstat(fd, &actual) || !same(&actual, expected))
        die("namespace identity");
    if (userfd < 0)
        return;
    int owner = ioctl(fd, NS_GET_USERNS);
    struct stat wanted;
    if (owner < 0 || fstat(owner, &actual) || fstat(userfd, &wanted) || !same(&actual, &wanted))
        die("namespace owner");
    close(owner);
}

static void mapped_map(const struct mapped_identity *identity) {
    const char *paths[] = {"/proc/self/uid_map", "/proc/self/gid_map"};
    unsigned bases[] = {identity->uid, identity->gid};
    for (unsigned i = 0; i < 2; i++) {
        char data[128], extra;
        int fd = open(paths[i], O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0)
            die("entry map");
        ssize_t count = read(fd, data, sizeof(data) - 1);
        close(fd);
        if (count <= 0 || count == (ssize_t)sizeof(data) - 1)
            die("entry map read");
        data[count] = 0;
        unsigned first, base, width;
        if (sscanf(data, "%u %u %u %c", &first, &base, &width, &extra) != 3 || first ||
            base != bases[i] || width != 65536)
            die("entry map identity");
    }
    int fd = open("/proc/self/setgroups", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    char value[16];
    if (fd < 0 || read(fd, value, sizeof(value)) != 6 || memcmp(value, "allow\n", 6))
        die("entry setgroups");
    close(fd);
}

static void listener(void) {
    owned.listener = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (owned.listener < 0)
        die("entry socket");
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    memcpy(address.sun_path, ENTRY_SOCKET, sizeof(ENTRY_SOCKET));
    if (bind(owned.listener, (struct sockaddr *)&address, sizeof(address)))
        die("entry listener bind");
    owned.socket_created = 1;
    if (chmod(ENTRY_SOCKET, 0600) || listen(owned.listener, 16))
        die("entry listener");
    int fd = open(SERVER_STATE, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0)
        die("server state");
    owned.server_created = 1;
    char value[256];
    int length = snprintf(value, sizeof(value), "%s %d %llu\n", owned.entry.generation, getpid(),
                          starttime(getpid()));
    write_all(fd, value, (size_t)length);
    close(fd);
}

static void serve(void) {
    int client = accept4(owned.listener, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
    if (client < 0)
        return;
    struct ucred credentials;
    socklen_t length = sizeof(credentials);
    struct packet request;
    char generation[128];
    struct pollfd pending = {.fd = client, .events = POLLIN};
    ssize_t count = -1;
    if (poll(&pending, 1, 100) > 0)
        count = recv(client, generation, sizeof(generation), MSG_DONTWAIT | MSG_TRUNC);
    if (!getsockopt(client, SOL_SOCKET, SO_PEERCRED, &credentials, &length) &&
        length == sizeof(credentials) && credentials.uid == 0 &&
        count == (ssize_t)strlen(owned.entry.generation) + 1 &&
        !memcmp(generation, owned.entry.generation, (size_t)count)) {
        request = (struct packet){.stage = 6, .entry = owned.entry};
        send_packet(client, &request, owned.handles, 5);
    }
    close(client);
}

int mapped_initialize(int argc, char **argv, void (*protect)(void), void (*apparmor)(void),
                      void (*policy)(void)) {
    if (argc < 4)
        return 64;
    if (mapped_inputs(argv[2], getenv("WORKSPACE_UID_BASE"), getenv("WORKSPACE_GID_BASE"),
                      getenv("WORKSPACE_DISK_BYTES"), &owned.entry.identity)) {
        errno = EINVAL;
        die("mandatory mapped inputs");
    }
    trusted_tool("/usr/local/libexec/fuse-overlayfs");
    trusted_tool("/usr/sbin/ip");
    trusted_tool("/usr/sbin/nft");
    trusted_tool("/usr/sbin/dnsmasq");
    memcpy(owned.entry.generation, argv[2], strlen(argv[2]) + 1);
    store_identity(&owned.entry.identity);
    if (atexit(cleanup))
        die("cleanup registration");
    struct sigaction action = {.sa_handler = stopped};
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGINT, &action, NULL) ||
        sigaction(SIGHUP, &action, NULL))
        die("signal setup");
    if (prctl(PR_SET_DUMPABLE, 0) || prctl(PR_SET_CHILD_SUBREAPER, 1))
        die("supervisor identity");
    owned.loop = prepare_disk_backing(argv[2], DISK_BYTES);
    if (chmod("/quota-runtime", 0755) || chmod("/quota-runtime/root", 0755))
        die("mount access");
    devices();
    state_volume(&owned.entry.identity);
    int channels[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, channels))
        die("bootstrap channel");
    struct timeval timeout = {.tv_sec = 30};
    for (unsigned i = 0; i < 2; i++) {
        if (setsockopt(channels[i], SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ||
            setsockopt(channels[i], SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)))
            die("bootstrap timeout");
    }
    owned.channel = channels[0];
    owned.keeper = fork();
    if (owned.keeper < 0)
        die("keeper fork");
    if (!owned.keeper) {
        owned.keeper = owned.fuse = 0;
        owned.listener = -1;
        owned.devices = 0;
        int status = keeper(channels[1], argv + 3, protect, apparmor, policy);
        _exit(status);
    }
    initial_apparmor(NULL);
    close(channels[1]);
    owned.entry.keeper = owned.keeper;
    owned.handles[4] = syscall(SYS_pidfd_open, owned.keeper, 0);
    if (owned.handles[4] < 0)
        die("keeper pidfd");
    owned.entry.starttime = starttime(owned.keeper);
    handshake(owned.channel, 0);
    map_file(owned.keeper, "uid_map", owned.entry.identity.uid);
    map_file(owned.keeper, "gid_map", owned.entry.identity.gid);
    signal_stage(owned.channel, 1);
    struct packet packet;
    int fuse;
    if (receive(owned.channel, &packet, &fuse, 1) || packet.stage != 2)
        die("fuse handshake");
    owned.fuse = start_fuse(fuse);
    close(fuse);
    signal_stage(owned.channel, 3);
    if (receive(owned.channel, &packet, owned.handles, 4) || packet.stage != 4)
        die("keeper ready");
    struct stat *identities[] = {&owned.entry.user, &owned.entry.mount, &owned.entry.network};
    const char *names[] = {"user handle identity", "mount handle identity",
                           "network handle identity"};
    for (unsigned i = 0; i < 3; i++)
        if (fstat(owned.handles[i], identities[i]))
            die(names[i]);
    namespace_check(owned.handles[0], CLONE_NEWUSER, &owned.entry.user, -1);
    namespace_check(owned.handles[1], CLONE_NEWNS, &owned.entry.mount, owned.handles[0]);
    namespace_check(owned.handles[2], CLONE_NEWNET, &owned.entry.network, owned.handles[0]);
    if (!S_ISDIR(packet.entry.root.st_mode) || packet.entry.root.st_uid ||
        packet.entry.root.st_gid) {
        errno = EPERM;
        die("keeper root metadata");
    }
    owned.entry.root = packet.entry.root;
    if (mapped_network_prepare(owned.handles[2], owned.handles[0], owned.handles[4], argv[2],
                               &owned.network))
        die("routed network");
    listener();
    struct packet network = {.stage = 5};
    memcpy(network.entry.generation, owned.network.outer_address,
           strlen(owned.network.outer_address) + 1);
    if (send_packet(owned.channel, &network, NULL, 0))
        die("network configuration");
    printf("READY %d %d\n", owned.keeper, owned.keeper);
    fflush(stdout);
    int result = 80;
    for (;;) {
        int status;
        pid_t child;
        while ((child = waitpid(-1, &status, WNOHANG)) > 0) {
            if (child == owned.keeper) {
                owned.keeper = 0;
                return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
            }
            if (child == owned.fuse) {
                owned.fuse = 0;
                return result;
            }
            if (child == owned.network.dns_pid) {
                owned.network.dns_pid = 0;
                close(owned.network.dns_fd);
                owned.network.dns_fd = -1;
                return result;
            }
        }
        if (stop_signal)
            return 0;
        struct pollfd event = {.fd = owned.listener, .events = POLLIN};
        if (poll(&event, 1, 100) > 0)
            serve();
    }
}

int mapped_enter(int argc, char **argv, void (*apparmor)(void), void (*policy)(void)) {
    if (argc < 4 || !argv[2][0] || strlen(argv[2]) > 127)
        return 64;
    struct stat socket_info;
    if (lstat(ENTRY_SOCKET, &socket_info) || !S_ISSOCK(socket_info.st_mode) || socket_info.st_uid ||
        socket_info.st_gid || (socket_info.st_mode & 0777) != 0600)
        die("entry socket identity");
    int channel = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (channel < 0)
        die("entry socket open");
    struct timeval timeout = {.tv_sec = 3};
    if (setsockopt(channel, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ||
        setsockopt(channel, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)))
        die("entry timeout");
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    memcpy(address.sun_path, ENTRY_SOCKET, sizeof(ENTRY_SOCKET));
    if (connect(channel, (struct sockaddr *)&address, sizeof(address)))
        die("entry connect");
    int state = open(SERVER_STATE, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    struct stat state_info;
    if (state < 0 || fstat(state, &state_info) || !S_ISREG(state_info.st_mode) ||
        state_info.st_uid || state_info.st_gid || state_info.st_nlink != 1 ||
        (state_info.st_mode & 0777) != 0600)
        die("server state identity");
    char value[256], generation[128], extra;
    ssize_t count = read(state, value, sizeof(value) - 1);
    close(state);
    if (count <= 0 || count == (ssize_t)sizeof(value) - 1)
        die("server state read");
    value[count] = 0;
    pid_t server;
    unsigned long long expected;
    if (sscanf(value, "%127s %d %llu %c", generation, &server, &expected, &extra) != 3 ||
        strcmp(generation, argv[2]) || server <= 0 || starttime(server) != expected)
        die("server state identity");
    struct ucred credentials;
    socklen_t length = sizeof(credentials);
    if (getsockopt(channel, SOL_SOCKET, SO_PEERCRED, &credentials, &length) ||
        length != sizeof(credentials) || credentials.uid || credentials.pid != server ||
        starttime(server) != expected)
        die("entry server identity");
    if (send(channel, argv[2], strlen(argv[2]) + 1, MSG_NOSIGNAL) != (ssize_t)strlen(argv[2]) + 1)
        die("entry request");
    struct packet packet;
    int handles[5];
    if (receive(channel, &packet, handles, 5) || packet.stage != 6)
        die("entry handles");
    close(channel);
    struct entry *entry = &packet.entry;
    if (entry->generation[127] || strcmp(entry->generation, argv[2]) || entry->keeper <= 1 ||
        starttime(entry->keeper) != entry->starttime)
        die("keeper identity");
    struct pollfd alive = {.fd = handles[4], .events = POLLIN};
    if (poll(&alive, 1, 0))
        die("keeper exited");
    namespace_check(handles[0], CLONE_NEWUSER, &entry->user, -1);
    namespace_check(handles[1], CLONE_NEWNS, &entry->mount, handles[0]);
    namespace_check(handles[2], CLONE_NEWNET, &entry->network, handles[0]);
    initial_apparmor(apparmor);
    if (setns(handles[0], CLONE_NEWUSER))
        die("enter user");
    mapped_map(&entry->identity);
    if (setns(handles[2], CLONE_NEWNET) || setns(handles[1], CLONE_NEWNS))
        die("enter network mount");
    if (setgroups(0, NULL) || setresgid(0, 0, 0) || setresuid(0, 0, 0) || prctl(PR_SET_DUMPABLE, 0))
        die("entry credentials");
    struct stat root;
    if (getuid() || geteuid() || getgid() || getegid() || getgroups(0, NULL) ||
        fstat(handles[3], &root) || !S_ISDIR(root.st_mode) || !same(&root, &entry->root) ||
        root.st_mode != entry->root.st_mode || root.st_uid || root.st_gid)
        die("entry root identity");
    if (poll(&alive, 1, 0))
        die("keeper closed");
    if (fchdir(handles[3]) || chroot(".") || chdir("/"))
        die("entry root");
    policy();
    execvp(argv[3], argv + 3);
    die("entry exec");
    return 80;
}
