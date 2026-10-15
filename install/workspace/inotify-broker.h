#ifndef CTFD_INOTIFY_BROKER_H
#define CTFD_INOTIFY_BROKER_H

#include <sys/types.h>

pid_t start_inotify_broker(const char *generation);
int open_inotify_broker(const char *generation);
void install_inotify_notification(int channel);

#endif
