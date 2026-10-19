#ifndef CTFD_DISK_SETUP_H
#define CTFD_DISK_SETUP_H

int prepare_disk_backing(const char *generation, unsigned long long bytes);
int prepare_disk(const char *generation, unsigned long long bytes);
void enter_disk_root(void);

#endif
