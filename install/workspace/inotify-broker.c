#define _GNU_SOURCE
#include "inotify-broker.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/capability.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef SECCOMP_ADDFD_FLAG_SEND
#define SECCOMP_ADDFD_FLAG_SEND (1UL << 1)
#endif

struct endpoint {
    int fd;
    int kind;
    int authenticated;
};

static void broker_fail(const char *what) {
    fprintf(stderr, "inotify broker %s errno %d %s\n", what, errno, strerror(errno));
    exit(80);
}

static void put_value(const char *path, const char *value) {
    int fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) broker_fail(path);
    size_t length = strlen(value);
    if (write(fd, value, length) != (ssize_t)length) broker_fail(path);
    close(fd);
}

static void byte_read(int fd) {
    char value;
    ssize_t length;
    do length = read(fd, &value, 1); while (length < 0 && errno == EINTR);
    if (length != 1) broker_fail("handshake read");
}

static void byte_write(int fd) {
    ssize_t length;
    do length = write(fd, "1", 1); while (length < 0 && errno == EINTR);
    if (length != 1) broker_fail("handshake write");
}

static struct sockaddr_un broker_address(void) {
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    snprintf(address.sun_path, sizeof(address.sun_path), "/state/broker");
    return address;
}

static void append_endpoint(struct endpoint **items, size_t *length, size_t *capacity,
                            int fd, int kind) {
    if (*length == *capacity) {
        size_t next = *capacity ? *capacity * 2 : 16;
        struct endpoint *resized = realloc(*items, next * sizeof(**items));
        if (!resized) broker_fail("endpoint allocation");
        *items = resized;
        *capacity = next;
    }
    (*items)[(*length)++] = (struct endpoint){.fd = fd, .kind = kind};
}

static void close_endpoint(struct endpoint *item) {
    close(item->fd);
    item->fd = -1;
}

static int receive_listener(int channel, char *data, size_t capacity, int *truncated) {
    char ancillary[CMSG_SPACE(sizeof(int) * 8)];
    struct iovec vector = {.iov_base = data, .iov_len = capacity};
    struct msghdr message = {.msg_iov = &vector, .msg_iovlen = 1,
        .msg_control = ancillary, .msg_controllen = sizeof(ancillary)};
    ssize_t length = recvmsg(channel, &message, MSG_DONTWAIT | MSG_CMSG_CLOEXEC);
    if (length <= 0) return (int)length;
    int received = -1;
    int count = 0;
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    while (header) {
        if (header->cmsg_len < CMSG_LEN(0)) break;
        if (header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS) {
            size_t bytes = header->cmsg_len - CMSG_LEN(0);
            int *fds = (int *)CMSG_DATA(header);
            for (size_t index = 0; index < bytes / sizeof(int); index++) {
                if (!count++) received = fds[index];
                else close(fds[index]);
            }
        }
        unsigned char *next = (unsigned char *)header + CMSG_ALIGN(header->cmsg_len);
        if (next + sizeof(*header) > (unsigned char *)message.msg_control + message.msg_controllen) break;
        header = (struct cmsghdr *)next;
    }
    *truncated = (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) || count > 1;
    if (*truncated && received >= 0) {
        close(received);
        received = -1;
    }
    if (received >= 0) return received + 1;
    return length > 0 ? -2 : (int)length;
}

static void respond_error(int listener, uint64_t identifier, int error) {
    struct seccomp_notif_resp response = {.id = identifier, .error = -error};
    if (ioctl(listener, SECCOMP_IOCTL_NOTIF_SEND, &response) && errno != ENOENT && errno != EINTR)
        broker_fail("notification error response");
}

static void service_notification(int listener) {
    struct seccomp_notif request;
    memset(&request, 0, sizeof(request));
    if (ioctl(listener, SECCOMP_IOCTL_NOTIF_RECV, &request)) {
        if (errno == EAGAIN || errno == EINTR || errno == ENOENT) return;
        broker_fail("notification receive");
    }
    uint32_t number = (uint32_t)request.data.nr;
    int flags = 0;
    if (request.data.arch == AUDIT_ARCH_X86_64) {
        number &= ~0x40000000U;
        if (number == 294) flags = (int)(uint32_t)request.data.args[0];
        else if (number != 253) {
            respond_error(listener, request.id, ENOSYS);
            return;
        }
    } else if (request.data.arch == AUDIT_ARCH_I386) {
        if (number == 332) flags = (int)(uint32_t)request.data.args[0];
        else if (number != 291) {
            respond_error(listener, request.id, ENOSYS);
            return;
        }
    } else {
        respond_error(listener, request.id, ENOSYS);
        return;
    }
    if (flags & ~(IN_CLOEXEC | IN_NONBLOCK)) {
        respond_error(listener, request.id, EINVAL);
        return;
    }
    if (ioctl(listener, SECCOMP_IOCTL_NOTIF_ID_VALID, &request.id)) return;
    int instance = inotify_init1(flags | IN_CLOEXEC);
    if (instance < 0) {
        respond_error(listener, request.id, errno);
        return;
    }
    struct seccomp_notif_addfd transfer = {.id = request.id,
        .flags = SECCOMP_ADDFD_FLAG_SEND, .srcfd = (uint32_t)instance,
        .newfd_flags = (flags & IN_CLOEXEC) ? O_CLOEXEC : 0};
    int result = ioctl(listener, SECCOMP_IOCTL_NOTIF_ADDFD, &transfer);
    int error = errno;
    close(instance);
    if (result < 0 && error != ENOENT && error != EINTR) respond_error(listener, request.id, error);
}

static void broker_loop(int listener, const char *generation) {
    struct endpoint *items = NULL;
    size_t length = 0, capacity = 0;
    append_endpoint(&items, &length, &capacity, listener, 0);
    for (;;) {
        size_t snapshot = length;
        struct pollfd *polls = calloc(snapshot, sizeof(*polls));
        if (!polls) broker_fail("poll allocation");
        for (size_t index = 0; index < snapshot; index++)
            polls[index] = (struct pollfd){.fd = items[index].fd, .events = POLLIN};
        int ready;
        do ready = poll(polls, (nfds_t)snapshot, -1); while (ready < 0 && errno == EINTR);
        if (ready < 0) broker_fail("poll");
        for (size_t index = 0; index < snapshot; index++) {
            short events = polls[index].revents;
            if (!events) continue;
            int fd = items[index].fd;
            int kind = items[index].kind;
            if (kind == 0) {
                for (;;) {
                    int channel = accept4(listener, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
                    if (channel < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
                    if (channel < 0 && errno == EINTR) continue;
                    if (channel < 0) broker_fail("accept");
                    append_endpoint(&items, &length, &capacity, channel, 1);
                }
                continue;
            }
            if (kind == 2) {
                if (events & POLLIN) service_notification(fd);
                if (events & (POLLHUP | POLLERR | POLLNVAL)) close_endpoint(&items[index]);
                continue;
            }
            if (!(events & POLLIN)) {
                if (events & (POLLHUP | POLLERR | POLLNVAL)) close_endpoint(&items[index]);
                continue;
            }
            if (!items[index].authenticated) {
                char value[128];
                ssize_t size = recv(fd, value, sizeof(value), MSG_DONTWAIT | MSG_TRUNC);
                size_t expected = strlen(generation) + 1;
                if (size != (ssize_t)expected || memcmp(value, generation, expected)) {
                    close_endpoint(&items[index]);
                    continue;
                }
                items[index].authenticated = 1;
                if (send(fd, "A", 1, MSG_NOSIGNAL) != 1) close_endpoint(&items[index]);
                continue;
            }
            char value[8] = {0};
            int truncated = 0;
            int transferred = receive_listener(fd, value, sizeof(value), &truncated);
            if (transferred > 0 && !truncated && value[0] == 'F') {
                int notification = transferred - 1;
                int flags = fcntl(notification, F_GETFL);
                if (flags < 0 || fcntl(notification, F_SETFL, flags | O_NONBLOCK)) {
                    close(notification);
                    close_endpoint(&items[index]);
                    continue;
                }
                append_endpoint(&items, &length, &capacity, notification, 2);
                send(fd, "L", 1, MSG_NOSIGNAL);
            } else if (transferred > 0) close(transferred - 1);
            close_endpoint(&items[index]);
        }
        free(polls);
        size_t keep = 0;
        for (size_t index = 0; index < length; index++) {
            if (items[index].fd >= 0) items[keep++] = items[index];
        }
        length = keep;
    }
}

pid_t start_inotify_broker(const char *generation) {
    if (!generation || !*generation || strlen(generation) >= 128) {
        errno = EINVAL;
        broker_fail("generation");
    }
    const char *identity = getenv("CTFD_USER_ID");
    unsigned long user_id = 0;
    if (!identity || *identity < '1' || *identity > '9') {
        errno = EINVAL;
        broker_fail("user id");
    }
    for (const char *digit = identity; *digit; digit++) {
        if (*digit < '0' || *digit > '9' || user_id > (2147483646UL - (*digit - '0')) / 10) {
            errno = EINVAL;
            broker_fail("user id");
        }
        user_id = user_id * 10 + (*digit - '0');
    }
    uid_t owner = (uid_t)(2147483648UL + user_id);
    int listener = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (listener < 0) broker_fail("socket");
    struct sockaddr_un address = broker_address();
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) ||
        chmod(address.sun_path, 0600) || listen(listener, 128)) broker_fail("listen");
    int ready[2], resume[2];
    if (pipe2(ready, O_CLOEXEC) || pipe2(resume, O_CLOEXEC)) broker_fail("handshake pipes");
    pid_t helper = fork();
    if (helper < 0) broker_fail("helper fork");
    if (!helper) {
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        close(ready[0]);
        close(resume[1]);
        struct __user_cap_header_struct header = {.version = _LINUX_CAPABILITY_VERSION_3};
        struct __user_cap_data_struct caps[2] = {{
            .effective = (1U << CAP_SYS_ADMIN), .permitted = (1U << CAP_SYS_ADMIN)}};
        if (seteuid(owner) || syscall(SYS_capset, &header, caps)) broker_fail("helper owner identity");
        if (unshare(CLONE_NEWUSER)) broker_fail("helper user namespace");
        byte_write(ready[1]);
        byte_read(resume[0]);
        close(ready[1]);
        close(resume[0]);
        if (setgid(0) || setuid(0)) broker_fail("helper mapped identity");
        const char *instances = getenv("WORKSPACE_INOTIFY_INSTANCES");
        const char *watches = getenv("WORKSPACE_INOTIFY_WATCHES");
        put_value("/proc/sys/user/max_inotify_instances", instances ? instances : "64");
        put_value("/proc/sys/user/max_inotify_watches", watches ? watches : "4096");
        if (prctl(PR_SET_DUMPABLE, 0)) broker_fail("helper dumpable");
        if (listener > 3 && syscall(SYS_close_range, 3U, (unsigned int)listener - 1U, 0))
            broker_fail("close helper lower descriptors");
        if (syscall(SYS_close_range, (unsigned int)listener + 1U, ~0U, 0))
            broker_fail("close helper upper descriptors");
        broker_loop(listener, generation);
        _exit(0);
    }
    close(listener);
    close(ready[1]);
    close(resume[0]);
    byte_read(ready[0]);
    char path[128];
    snprintf(path, sizeof(path), "/proc/%d/uid_map", helper);
    put_value(path, "0 65534 1\n");
    snprintf(path, sizeof(path), "/proc/%d/gid_map", helper);
    put_value(path, "0 65534 1\n");
    byte_write(resume[1]);
    close(ready[0]);
    close(resume[1]);
    return helper;
}

int open_inotify_broker(const char *generation) {
    if (!generation || !*generation || strlen(generation) >= 128) {
        errno = EINVAL;
        broker_fail("connect generation");
    }
    int channel = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (channel < 0) broker_fail("channel socket");
    struct sockaddr_un address = broker_address();
    if (connect(channel, (struct sockaddr *)&address, sizeof(address))) broker_fail("channel connect");
    size_t length = strlen(generation) + 1;
    if (send(channel, generation, length, MSG_NOSIGNAL) != (ssize_t)length)
        broker_fail("channel authenticate");
    char ack;
    if (recv(channel, &ack, 1, 0) != 1 || ack != 'A') broker_fail("channel authentication ack");
    return channel;
}

void install_inotify_notification(int channel) {
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 0, 8),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 253, 18, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 294, 17, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0x40000000U | 253U, 16, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0x40000000U | 294U, 15, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 317, 8, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0x40000000U | 317U, 7, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_I386, 0, 12),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 291, 9, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 332, 8, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 354, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SECCOMP_SET_MODE_FILTER, 0, 3),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[1])),
        BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, SECCOMP_FILTER_FLAG_NEW_LISTENER, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_USER_NOTIF),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
    };
    struct sock_fprog program = {.len = sizeof(instructions) / sizeof(instructions[0]),
        .filter = instructions};
    int listener = (int)syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER,
        SECCOMP_FILTER_FLAG_NEW_LISTENER, &program);
    if (listener < 0) broker_fail("install notification filter");
    char ancillary[CMSG_SPACE(sizeof(int))];
    struct iovec vector = {.iov_base = "F", .iov_len = 1};
    struct msghdr message = {.msg_iov = &vector, .msg_iovlen = 1,
        .msg_control = ancillary, .msg_controllen = sizeof(ancillary)};
    memset(ancillary, 0, sizeof(ancillary));
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &listener, sizeof(listener));
    if (sendmsg(channel, &message, MSG_NOSIGNAL) != 1) broker_fail("send notification listener");
    char ack;
    if (recv(channel, &ack, 1, 0) != 1 || ack != 'L') broker_fail("notification listener ack");
    close(listener);
    close(channel);
}
