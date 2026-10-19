#ifndef MAPPED_NETWORK_H
#define MAPPED_NETWORK_H

#include <sys/types.h>

struct mapped_network {
    char outer_address[16];
    char inner_address[16];
    char docker_address[16];
    char outer_link[16];
    char table[40];
    char generation[128];
    pid_t dns_pid;
    int dns_fd;
    int link_created;
    int table_created;
};

int mapped_network_prepare(int netfd, int userfd, int keeperfd, const char *generation,
                           struct mapped_network *state);
int mapped_network_cleanup(struct mapped_network *state);

#endif
