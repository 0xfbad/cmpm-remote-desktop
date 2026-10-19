#define _GNU_SOURCE
#include "mapped-network.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <ifaddrs.h>
#include <linux/capability.h>
#include <linux/nsfs.h>
#include <net/if.h>
#include <poll.h>
#include <pwd.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

struct prefix {
    uint32_t address;
    uint32_t mask;
};
struct topology {
    struct prefix excluded[256];
    size_t count;
    char egress[16];
    char address[16];
    char resolvers[8][16];
    size_t resolver_count;
    int mtu;
};

static int reject(int error) {
    errno = error;
    return -1;
}

static int wait_process(pid_t pid, int handle, int milliseconds, int *status) {
    struct timespec start, now;
    if (clock_gettime(CLOCK_MONOTONIC, &start))
        return -1;
    for (;;) {
        if (clock_gettime(CLOCK_MONOTONIC, &now))
            return -1;
        long elapsed = (now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000;
        int remaining = elapsed >= milliseconds ? 0 : milliseconds - (int)elapsed;
        struct pollfd item = {.fd = handle, .events = POLLIN};
        int result = poll(&item, 1, remaining);
        if (result < 0 && errno == EINTR)
            continue;
        if (result < 0)
            return -1;
        if (!result)
            return reject(ETIMEDOUT);
        if (!(item.revents & POLLIN))
            return reject(EIO);
        pid_t waited;
        do
            waited = waitpid(pid, status, 0);
        while (waited < 0 && errno == EINTR);
        return waited == pid ? 0 : -1;
    }
}

static int run_tool(int namespace_fd, int inherited_fd, const char *const arguments[],
                    const char *input) {
    int stream[2] = {-1, -1};
    if (input && strlen(input) > 4096)
        return reject(E2BIG);
    if (input && socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, stream))
        return -1;
    pid_t pid = fork();
    if (pid < 0) {
        int error = errno;
        if (input) {
            close(stream[0]);
            close(stream[1]);
        }
        return reject(error);
    }
    if (!pid) {
        if (namespace_fd >= 0 && setns(namespace_fd, CLONE_NEWNET))
            _exit(121);
        int source = input ? stream[1] : open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (source < 0 || dup2(source, 0) < 0)
            _exit(122);
        if (inherited_fd >= 0) {
            if (dup2(inherited_fd, 3) < 0 || fcntl(3, F_SETFD, 0))
                _exit(123);
        }
        if (syscall(SYS_close_range, inherited_fd >= 0 ? 4U : 3U, ~0U, 0))
            _exit(124);
        char *const environment[] = {"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C", NULL};
        execve(arguments[0], (char *const *)arguments, environment);
        _exit(125);
    }
    if (input)
        close(stream[1]);
    int handle = syscall(SYS_pidfd_open, pid, 0);
    int error = handle < 0 ? errno : 0;
    if (input) {
        size_t sent = 0, length = strlen(input);
        while (!error && sent < length) {
            ssize_t n = send(stream[0], input + sent, length - sent, MSG_NOSIGNAL);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0) {
                error = n < 0 ? errno : EIO;
                break;
            }
            sent += (size_t)n;
        }
        close(stream[0]);
    }
    int status = 0;
    if (!error && wait_process(pid, handle, 5000, &status))
        error = errno;
    if (error) {
        if (handle >= 0)
            syscall(SYS_pidfd_send_signal, handle, SIGKILL, NULL, 0);
        else
            kill(pid, SIGKILL);
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        }
    } else if (!WIFEXITED(status) || WEXITSTATUS(status)) {
        fprintf(stderr, "network tool %s status %d\n", arguments[0], status);
        error = EIO;
    }
    if (handle >= 0)
        close(handle);
    return error ? reject(error) : 0;
}

static int exclude(struct topology *plan, uint32_t address, uint32_t mask) {
    if (plan->count == sizeof(plan->excluded) / sizeof(plan->excluded[0]))
        return reject(E2BIG);
    plan->excluded[plan->count++] = (struct prefix){address, mask};
    return 0;
}

static int interface_name(const char *name) {
    if (!*name || strlen(name) >= 16)
        return 0;
    for (const unsigned char *p = (const unsigned char *)name; *p; p++) {
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9') ||
              strchr("_.:-", *p)))
            return 0;
    }
    return 1;
}

static int read_topology(struct topology *plan) {
    memset(plan, 0, sizeof(*plan));
    FILE *routes = fopen("/proc/net/route", "re");
    if (!routes)
        return -1;
    char line[1024];
    unsigned long best = ~0UL;
    while (fgets(line, sizeof(line), routes)) {
        char name[16];
        unsigned long destination, gateway, mask, metric;
        unsigned int flags;
        if (sscanf(line, "%15s %lx %lx %x %*u %*u %lu %lx", name, &destination, &gateway, &flags,
                   &metric, &mask) != 6)
            continue;
        if (!interface_name(name) || !(flags & 1))
            continue;
        if (!destination && !mask && metric < best) {
            snprintf(plan->egress, sizeof(plan->egress), "%s", name);
            best = metric;
        }
        if (mask && exclude(plan, ntohl((uint32_t)destination), ntohl((uint32_t)mask))) {
            int error = errno;
            fclose(routes);
            return reject(error);
        }
    }
    int failed = ferror(routes);
    fclose(routes);
    if (failed)
        return reject(EIO);
    if (!plan->egress[0] || !strcmp(plan->egress, "lo"))
        return reject(ENETUNREACH);
    struct ifaddrs *addresses;
    if (getifaddrs(&addresses))
        return -1;
    int matches = 0, error = 0;
    for (struct ifaddrs *row = addresses; row; row = row->ifa_next) {
        if (!row->ifa_addr || row->ifa_addr->sa_family != AF_INET || !row->ifa_netmask)
            continue;
        struct sockaddr_in *address = (struct sockaddr_in *)row->ifa_addr;
        struct sockaddr_in *mask = (struct sockaddr_in *)row->ifa_netmask;
        if (exclude(plan, ntohl(address->sin_addr.s_addr), ntohl(mask->sin_addr.s_addr))) {
            error = errno;
            break;
        }
        if (!strcmp(row->ifa_name, plan->egress)) {
            matches++;
            if (!inet_ntop(AF_INET, &address->sin_addr, plan->address, sizeof(plan->address))) {
                error = errno;
                break;
            }
        }
    }
    freeifaddrs(addresses);
    if (error)
        return reject(error);
    if (matches != 1)
        return reject(EADDRNOTAVAIL);
    int connection = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (connection < 0)
        return -1;
    struct ifreq request = {0};
    snprintf(request.ifr_name, sizeof(request.ifr_name), "%s", plan->egress);
    int result = ioctl(connection, SIOCGIFMTU, &request);
    error = errno;
    close(connection);
    if (result)
        return reject(error);
    plan->mtu = request.ifr_mtu;
    if (plan->mtu < 1280 || plan->mtu > 65535)
        return reject(EINVAL);
    error = 0;
    FILE *resolvers = fopen("/etc/resolv.conf", "re");
    if (!resolvers)
        return -1;
    while (fgets(line, sizeof(line), resolvers)) {
        char keyword[32], address[128];
        if (sscanf(line, "%31s %127s", keyword, address) != 2 || strcmp(keyword, "nameserver"))
            continue;
        struct in_addr value;
        if (inet_pton(AF_INET, address, &value) != 1 || plan->resolver_count == 8) {
            error = EINVAL;
            break;
        }
        if (exclude(plan, ntohl(value.s_addr), UINT32_MAX)) {
            error = errno;
            break;
        }
        if (!inet_ntop(AF_INET, &value, plan->resolvers[plan->resolver_count++], 16)) {
            error = errno;
            break;
        }
    }
    if (!error && ferror(resolvers))
        error = EIO;
    fclose(resolvers);
    if (error)
        return reject(error);
    return plan->resolver_count ? 0 : reject(EADDRNOTAVAIL);
}

static uint64_t generation_hash(const char *generation) {
    uint64_t hash = UINT64_C(14695981039346656037);
    for (const unsigned char *p = (const unsigned char *)generation; *p; p++)
        hash = (hash ^ *p) * UINT64_C(1099511628211);
    return hash;
}

static int choose_subnet(const struct topology *plan, uint64_t hash, struct mapped_network *state) {
    for (unsigned int n = 0; n < 32768; n++) {
        uint32_t candidate = UINT32_C(0xc6120000) + (((unsigned int)hash + n) % 32768) * 4;
        int available = 1;
        for (size_t i = 0; i < plan->count; i++) {
            uint32_t common = UINT32_C(0xfffffffc) & plan->excluded[i].mask;
            if ((candidate & common) == (plan->excluded[i].address & common)) {
                available = 0;
                break;
            }
        }
        if (!available)
            continue;
        struct in_addr outside = {.s_addr = htonl(candidate + 1)};
        struct in_addr inside = {.s_addr = htonl(candidate + 2)};
        if (!inet_ntop(AF_INET, &outside, state->outer_address, 16) ||
            !inet_ntop(AF_INET, &inside, state->inner_address, 16))
            return -1;
        return 0;
    }
    return reject(EADDRINUSE);
}

static int start_dns(const struct topology *plan, struct mapped_network *state) {
    struct passwd *user = getpwuid(65534);
    if (!user || user->pw_uid != 65534 || user->pw_gid != 65534)
        return reject(EINVAL);
    char user_option[256], group_option[256];
    if (snprintf(user_option, sizeof(user_option), "--user=%s", user->pw_name) >=
        (int)sizeof(user_option))
        return reject(E2BIG);
    struct group *group = getgrgid(65534);
    if (!group || group->gr_gid != 65534 ||
        snprintf(group_option, sizeof(group_option), "--group=%s", group->gr_name) >=
            (int)sizeof(group_option))
        return reject(EINVAL);
    user = getpwnam(user_option + 7);
    group = getgrnam(group_option + 8);
    if (!user || user->pw_uid != 65534 || user->pw_gid != 65534 || !group || group->gr_gid != 65534)
        return reject(EINVAL);
    char listen[64], servers[8][64];
    snprintf(listen, sizeof(listen), "--listen-address=%s", state->outer_address);
    const char *arguments[32] = {"/usr/sbin/dnsmasq",
                                 "--keep-in-foreground",
                                 "--conf-file=/dev/null",
                                 "--no-resolv",
                                 "--no-hosts",
                                 "--cache-size=0",
                                 "--proxy-dnssec",
                                 "--bind-interfaces",
                                 listen,
                                 "--port=1053",
                                 "--pid-file=",
                                 "--log-facility=-",
                                 user_option,
                                 group_option};
    for (size_t i = 0; i < plan->resolver_count; i++) {
        snprintf(servers[i], sizeof(servers[i]), "--server=%s#53", plan->resolvers[i]);
        arguments[14 + i] = servers[i];
    }
    pid_t parent = getpid();
    pid_t pid = fork();
    if (pid < 0)
        return -1;
    if (!pid) {
        int input = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (input < 0 || dup2(input, 0) < 0 || syscall(SYS_close_range, 3U, ~0U, 0))
            _exit(126);
        if (setgroups(0, NULL))
            _exit(127);
        for (int cap = 0; cap <= CAP_LAST_CAP; cap++)
            if (prctl(PR_CAPBSET_DROP, cap, 0, 0, 0))
                _exit(127);
        if (setgid(65534) || setuid(65534) ||
            prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) ||
            prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) ||
            getppid() != parent)
            _exit(127);
        struct __user_cap_header_struct header = {.version = _LINUX_CAPABILITY_VERSION_3};
        struct __user_cap_data_struct capabilities[2] = {0};
        if (syscall(SYS_capget, &header, &capabilities) || capabilities[0].effective ||
            capabilities[0].permitted || capabilities[0].inheritable || capabilities[1].effective ||
            capabilities[1].permitted || capabilities[1].inheritable)
            _exit(127);
        char *const environment[] = {"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C", NULL};
        execve(arguments[0], (char *const *)arguments, environment);
        _exit(127);
    }
    state->dns_pid = pid;
    state->dns_fd = syscall(SYS_pidfd_open, pid, 0);
    if (state->dns_fd < 0)
        return -1;
    for (int i = 0; i < 60; i++) {
        struct pollfd alive = {.fd = state->dns_fd, .events = POLLIN};
        if (poll(&alive, 1, 0) != 0)
            return reject(ECHILD);
        int connection = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (connection < 0)
            return -1;
        struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(1053)};
        inet_pton(AF_INET, state->outer_address, &address.sin_addr);
        int connected = connect(connection, (struct sockaddr *)&address, sizeof(address));
        int error = errno;
        if (connected < 0 && error == EINPROGRESS) {
            struct pollfd ready = {.fd = connection, .events = POLLOUT};
            if (poll(&ready, 1, 50) > 0) {
                socklen_t size = sizeof(error);
                if (getsockopt(connection, SOL_SOCKET, SO_ERROR, &error, &size))
                    error = errno;
                connected = error ? -1 : 0;
            }
        }
        close(connection);
        if (!connected) {
            if (poll(&alive, 1, 0) != 0)
                return reject(ECHILD);
            return 0;
        }
        struct timespec pause = {.tv_nsec = 50000000};
        nanosleep(&pause, NULL);
    }
    return reject(ETIMEDOUT);
}

int mapped_network_prepare(int netfd, int userfd, int keeperfd, const char *generation,
                           struct mapped_network *state) {
    memset(state, 0, sizeof(*state));
    state->dns_fd = -1;
    if (!generation || !*generation || strlen(generation) >= sizeof(state->generation))
        return reject(EINVAL);
    for (const unsigned char *p = (const unsigned char *)generation; *p; p++) {
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9') ||
              *p == '-' || *p == '_'))
            return reject(EINVAL);
    }
    if (ioctl(netfd, NS_GET_NSTYPE) != CLONE_NEWNET)
        return reject(EINVAL);
    int owner = ioctl(netfd, NS_GET_USERNS);
    if (owner < 0)
        return -1;
    struct stat expected, actual;
    int checked = fstat(userfd, &expected) || fstat(owner, &actual);
    int error = errno;
    close(owner);
    if (checked)
        return reject(error);
    if (expected.st_dev != actual.st_dev || expected.st_ino != actual.st_ino)
        return reject(EINVAL);
    struct pollfd keeper = {.fd = keeperfd, .events = POLLIN};
    if (poll(&keeper, 1, 0) != 0)
        return reject(ECHILD);
    FILE *forwarding = fopen("/proc/sys/net/ipv4/ip_forward", "re");
    if (!forwarding)
        return -1;
    int enabled = fgetc(forwarding);
    fclose(forwarding);
    if (enabled != '1')
        return reject(EINVAL);
    struct topology plan;
    if (read_topology(&plan))
        return -1;
    uint64_t hash = generation_hash(generation);
    if (choose_subnet(&plan, hash, state))
        return -1;
    snprintf(state->outer_link, sizeof(state->outer_link), "g%010llx",
             (unsigned long long)(hash & UINT64_C(0xffffffffff)));
    char inner_link[16];
    snprintf(inner_link, sizeof(inner_link), "p%010llx",
             (unsigned long long)(hash & UINT64_C(0xffffffffff)));
    snprintf(state->table, sizeof(state->table), "rd_%016llx", (unsigned long long)hash);
    snprintf(state->docker_address, sizeof(state->docker_address), "%s", plan.address);
    snprintf(state->generation, sizeof(state->generation), "%s", generation);
    if (if_nametoindex(state->outer_link) || if_nametoindex(inner_link))
        return reject(EEXIST);
    const char *create[] = {"/usr/sbin/ip", "link",     "add",  "name", state->outer_link,
                            "alias",        generation, "type", "veth", "peer",
                            "name",         inner_link, NULL};
    if (run_tool(-1, -1, create, NULL))
        return -1;
    state->link_created = 1;
    const char *move[] = {"/usr/sbin/ip",    "link", "set", "dev", inner_link, "netns",
                          "/proc/self/fd/3", NULL};
    if (run_tool(-1, netfd, move, NULL))
        return -1;
    char mtu[16], outer[24];
    snprintf(mtu, sizeof(mtu), "%d", plan.mtu);
    snprintf(outer, sizeof(outer), "%s/30", state->outer_address);
    const char *up[] = {"/usr/sbin/ip", "link", "set", "dev", state->outer_link,
                        "mtu",          mtu,    "up",  NULL};
    const char *address[] = {"/usr/sbin/ip", "address",         "add", outer,
                             "dev",          state->outer_link, NULL};
    if (run_tool(-1, -1, up, NULL) || run_tool(-1, -1, address, NULL))
        return -1;
    char input[4096];
    int length = snprintf(input, sizeof(input),
                          "link set dev lo up\nlink set dev %s mtu %d up\naddress add %s/30 dev "
                          "%s\nroute add default via %s dev %s\n",
                          inner_link, plan.mtu, state->inner_address, inner_link,
                          state->outer_address, inner_link);
    if (length < 0 || length >= (int)sizeof(input))
        return reject(E2BIG);
    const char *inner[] = {"/usr/sbin/ip", "-batch", "-", NULL};
    if (run_tool(netfd, -1, inner, input))
        return -1;
    length = snprintf(
        input, sizeof(input),
        "create table ip %s { comment \"%s\"; }\n"
        "add chain ip %s prerouting { type nat hook prerouting priority dstnat; policy accept; }\n"
        "add chain ip %s postrouting { type nat hook postrouting priority srcnat; policy accept; "
        "}\n"
        "add rule ip %s prerouting iifname \"%s\" tcp dport { 22, 6080, 7682 } dnat to %s\n"
        "add rule ip %s postrouting iifname \"%s\" oifname \"%s\" ip saddr %s masquerade\n"
        "add rule ip %s prerouting iifname \"%s\" ip daddr %s tcp dport { 22, 6080, 7682 } dnat to "
        "%s\n"
        "add rule ip %s postrouting iifname \"%s\" oifname \"%s\" ip saddr %s ip daddr %s tcp "
        "dport { 22, 6080, 7682 } snat to %s\n"
        "add rule ip %s prerouting iifname \"%s\" ip daddr %s udp dport 53 redirect to :1053\n"
        "add rule ip %s prerouting iifname \"%s\" ip daddr %s tcp dport 53 redirect to :1053\n",
        state->table, generation, state->table, state->table, state->table, plan.egress,
        state->inner_address, state->table, state->outer_link, plan.egress, state->inner_address,
        state->table, state->outer_link, state->docker_address, state->inner_address, state->table,
        state->outer_link, state->outer_link, state->inner_address, state->inner_address,
        state->outer_address, state->table, state->outer_link, state->outer_address, state->table,
        state->outer_link, state->outer_address);
    if (length < 0 || length >= (int)sizeof(input))
        return reject(E2BIG);
    const char *nft[] = {"/usr/sbin/nft", "-f", "-", NULL};
    if (run_tool(-1, -1, nft, input))
        return -1;
    state->table_created = 1;
    return start_dns(&plan, state);
}

int mapped_network_cleanup(struct mapped_network *state) {
    int error = 0;
    if (state->dns_pid > 0) {
        if (state->dns_fd >= 0) {
            if (syscall(SYS_pidfd_send_signal, state->dns_fd, SIGTERM, NULL, 0) && errno != ESRCH)
                error = errno;
        } else if (kill(state->dns_pid, SIGTERM) && errno != ESRCH)
            error = errno;
        int status = 0;
        if (state->dns_fd < 0 || wait_process(state->dns_pid, state->dns_fd, 3000, &status)) {
            if (!error)
                error = errno;
            if (state->dns_fd >= 0)
                syscall(SYS_pidfd_send_signal, state->dns_fd, SIGKILL, NULL, 0);
            else
                kill(state->dns_pid, SIGKILL);
            while (waitpid(state->dns_pid, &status, 0) < 0 && errno == EINTR) {
            }
        } else if ((!WIFEXITED(status) || WEXITSTATUS(status)) && !error)
            error = EIO;
        state->dns_pid = 0;
    }
    if (state->dns_fd >= 0) {
        if (close(state->dns_fd) && !error)
            error = errno;
        state->dns_fd = -1;
    }
    if (state->table_created) {
        const char *remove[] = {"/usr/sbin/nft", "delete", "table", "ip", state->table, NULL};
        if (run_tool(-1, -1, remove, NULL)) {
            if (!error)
                error = errno;
        } else
            state->table_created = 0;
    }
    if (state->link_created) {
        char path[128], alias[128];
        snprintf(path, sizeof(path), "/sys/class/net/%s/ifalias", state->outer_link);
        FILE *source = fopen(path, "re");
        if (!source) {
            if (!error)
                error = errno;
        } else {
            int valid = fgets(alias, sizeof(alias), source) != NULL;
            fclose(source);
            if (valid)
                alias[strcspn(alias, "\n")] = 0;
            if (!valid || strcmp(alias, state->generation)) {
                if (!error)
                    error = EPERM;
            } else {
                const char *remove[] = {"/usr/sbin/ip",    "link", "delete", "dev",
                                        state->outer_link, NULL};
                if (run_tool(-1, -1, remove, NULL)) {
                    if (!error)
                        error = errno;
                } else
                    state->link_created = 0;
            }
        }
    }
    return error ? reject(error) : 0;
}
