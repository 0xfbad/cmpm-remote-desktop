#ifndef CTFD_MAPPED_RUNTIME_H
#define CTFD_MAPPED_RUNTIME_H

#include <sys/types.h>

struct mapped_identity {
    uid_t uid;
    gid_t gid;
};

int mapped_inputs(const char *generation, const char *uid, const char *gid, const char *bytes,
                  struct mapped_identity *identity);
int mapped_initialize(int argc, char **argv, void (*protect)(void), void (*apparmor)(void),
                      void (*policy)(void));
int mapped_enter(int argc, char **argv, void (*apparmor)(void), void (*policy)(void));

#endif
