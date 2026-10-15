#define _GNU_SOURCE
#include "disk-setup.h"
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/loop.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void disk_fail(const char *what) {
    fprintf(stderr, "disk %s errno %d %s\n", what, errno, strerror(errno));
    exit(80);
}

static void directory(const char *path, mode_t mode) {
    if (mkdir(path, mode) && errno != EEXIST) disk_fail(path);
    struct stat info;
    if (lstat(path, &info) || !S_ISDIR(info.st_mode)) disk_fail(path);
}

static void disk_mount(const char *source, const char *target, const char *type,
                       unsigned long flags, const char *data) {
    if (mount(source, target, type, flags, data)) disk_fail(target);
}

static void copy_file(const char *source, const char *target) {
    int input = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (input < 0) disk_fail(source);
    int output = open(target, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0644);
    if (output < 0) disk_fail(target);
    char data[8192];
    for (;;) {
        ssize_t count = read(input, data, sizeof(data));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) disk_fail(source);
        if (!count) break;
        for (ssize_t offset = 0; offset < count;) {
            ssize_t written = write(output, data + offset, (size_t)(count - offset));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) disk_fail(target);
            offset += written;
        }
    }
    if (fchmod(output, 0644)) disk_fail(target);
    close(input);
    if (close(output)) disk_fail(target);
}

static void format_image(void) {
    pid_t child = fork();
    if (child < 0) disk_fail("format fork");
    if (!child) {
        if (syscall(SYS_close_range, 3U, ~0U, 0) && errno != ENOSYS) _exit(81);
        char *const arguments[] = {"/usr/sbin/mke2fs", "-q", "-t", "ext4", "-m", "0",
            "-E", "lazy_itable_init=0,lazy_journal_init=0", "/quota-store/root.img", NULL};
        char *const environment[] = {"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C", NULL};
        execve(arguments[0], arguments, environment);
        _exit(82);
    }
    int status;
    pid_t waited;
    do waited = waitpid(child, &status, 0); while (waited < 0 && errno == EINTR);
    if (waited < 0 || !WIFEXITED(status) || WEXITSTATUS(status)) disk_fail("format image");
}

static int configure_loop(int backing) {
    int control = open("/dev/loop-control", O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (control < 0) disk_fail("loop control");
    struct timespec retry = {.tv_nsec = 10000000};
    for (int attempt = 0; attempt < 64; attempt++) {
        int number = ioctl(control, LOOP_CTL_GET_FREE);
        if (number < 0) disk_fail("free loop");
        char path[64];
        snprintf(path, sizeof(path), "/dev/loop%d", number);
        if (mknod(path, S_IFBLK | 0600, makedev(7, (unsigned int)number)) && errno != EEXIST)
            disk_fail(path);
        struct stat info;
        if (lstat(path, &info) || !S_ISBLK(info.st_mode) || info.st_rdev != makedev(7, (unsigned int)number))
            disk_fail("loop device identity");
        int loop = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
        if (loop < 0) disk_fail(path);
        struct loop_config config = {.fd = (uint32_t)backing};
        config.info.lo_flags = LO_FLAGS_AUTOCLEAR;
        snprintf((char *)config.info.lo_file_name, LO_NAME_SIZE, "/quota-store/root.img");
        if (!ioctl(loop, LOOP_CONFIGURE, &config)) {
            close(control);
            return loop;
        }
        int error = errno;
        close(loop);
        if (error != EBUSY) {
            errno = error;
            disk_fail("configure loop");
        }
        nanosleep(&retry, NULL);
    }
    close(control);
    errno = EBUSY;
    disk_fail("loop allocation retry");
    return -1;
}

static void character(const char *name, unsigned int major_number, unsigned int minor_number) {
    char path[256];
    snprintf(path, sizeof(path), "/quota-runtime/root/dev/%s", name);
    if (unlink(path) && errno != ENOENT) disk_fail(path);
    if (mknod(path, S_IFCHR | 0666, makedev(major_number, minor_number)) || chmod(path, 0666))
        disk_fail(path);
}

static void device_link(const char *name, const char *target) {
    char path[256];
    snprintf(path, sizeof(path), "/quota-runtime/root/dev/%s", name);
    if (unlink(path) && errno != ENOENT) disk_fail(path);
    if (symlink(target, path)) disk_fail(path);
}

int prepare_disk(const char *generation, unsigned long long bytes) {
    if (!generation || !*generation || strlen(generation) > 127) {
        errno = EINVAL;
        disk_fail("generation");
    }
    for (const unsigned char *at = (const unsigned char *)generation; *at; at++) {
        if (!isalnum(*at) && *at != '-' && *at != '_') {
            errno = EINVAL;
            disk_fail("generation characters");
        }
    }
    if (bytes < 16ULL * 1024 * 1024 || bytes > 1024ULL * 1024 * 1024 * 1024) {
        errno = EINVAL;
        disk_fail("disk bytes");
    }
    disk_mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL);
    directory("/quota-runtime/base", 0700);
    directory("/quota-runtime/fs", 0700);
    directory("/quota-runtime/root", 0700);
    int created = 1;
    int backing = open("/quota-store/root.img", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (backing < 0 && errno == EEXIST) {
        created = 0;
        backing = open("/quota-store/root.img", O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    }
    if (backing < 0) disk_fail("disk backing");
    struct stat info;
    if (fstat(backing, &info) || !S_ISREG(info.st_mode) || info.st_nlink != 1 || info.st_uid != 0)
        disk_fail("disk backing identity");
    if (created) {
        if (ftruncate(backing, (off_t)bytes)) disk_fail("disk size");
        format_image();
    } else if ((unsigned long long)info.st_size != bytes) {
        errno = EINVAL;
        disk_fail("existing disk size");
    }
    int loop = configure_loop(backing);
    close(backing);
    struct loop_info64 loop_info;
    if (ioctl(loop, LOOP_GET_STATUS64, &loop_info)) disk_fail("loop status");
    char device[64];
    snprintf(device, sizeof(device), "/dev/loop%u", loop_info.lo_number);
    disk_mount(device, "/quota-runtime/fs", "ext4", 0, "discard");
    directory("/quota-runtime/fs/upper", 0755);
    directory("/quota-runtime/fs/work", 0700);
    disk_mount("/", "/quota-runtime/base", NULL, MS_BIND, NULL);
    disk_mount(NULL, "/quota-runtime/base", NULL, MS_BIND | MS_REMOUNT | MS_RDONLY, NULL);
    disk_mount("overlay", "/quota-runtime/root", "overlay", 0,
        "lowerdir=/quota-runtime/base,upperdir=/quota-runtime/fs/upper,workdir=/quota-runtime/fs/work,index=off");
    directory("/quota-runtime/root/.oldroot", 0700);
    directory("/quota-runtime/root/dev", 0755);
    directory("/quota-runtime/root/dev/pts", 0755);
    directory("/quota-runtime/root/dev/shm", 01777);
    if (chmod("/quota-runtime/root/dev/shm", 01777)) disk_fail("shm mode");
    disk_mount("/dev/shm", "/quota-runtime/root/dev/shm", NULL, MS_BIND, NULL);
    directory("/quota-runtime/root/proc", 0555);
    directory("/quota-runtime/root/state", 0700);
    directory("/quota-runtime/root/var/lib/remote-desktop", 0700);
    const char *files[] = {"hosts", "hostname", "resolv.conf"};
    for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
        char source[128], target[256];
        snprintf(source, sizeof(source), "/etc/%s", files[i]);
        snprintf(target, sizeof(target), "/quota-runtime/root/etc/%s", files[i]);
        copy_file(source, target);
    }
    disk_mount("/var/lib/remote-desktop", "/quota-runtime/root/var/lib/remote-desktop", NULL, MS_BIND, NULL);
    return loop;
}

void enter_disk_root(void) {
    if (unshare(CLONE_NEWNS)) disk_fail("disk mount namespace");
    disk_mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL);
    character("null", 1, 3);
    character("zero", 1, 5);
    character("full", 1, 7);
    character("random", 1, 8);
    character("urandom", 1, 9);
    character("tty", 5, 0);
    device_link("ptmx", "pts/ptmx");
    device_link("fd", "/proc/self/fd");
    device_link("stdin", "/proc/self/fd/0");
    device_link("stdout", "/proc/self/fd/1");
    device_link("stderr", "/proc/self/fd/2");
    disk_mount("devpts", "/quota-runtime/root/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC,
        "newinstance,ptmxmode=0666,mode=0620,max=128");
    if (chdir("/quota-runtime/root") || syscall(SYS_pivot_root, ".", ".oldroot") || chdir("/"))
        disk_fail("pivot disk root");
    if (umount2("/.oldroot", MNT_DETACH) || rmdir("/.oldroot")) disk_fail("detach old root");
    disk_mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
}
