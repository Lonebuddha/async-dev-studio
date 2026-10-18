#ifndef STUDIO_PTY_SUPPORT_H
#define STUDIO_PTY_SUPPORT_H
#include <sys/types.h>
#include <stdint.h>
// All arguments are allocated before fork. The child uses only async-signal-safe calls.
pid_t studio_pty_spawn(const char *executable, char *const argv[], char *const envp[],
                      const char *directory, unsigned short columns, unsigned short rows,
                      int *master, int *exec_error);
int studio_pty_resize(int fd, unsigned short columns, unsigned short rows);
int studio_process_exit_code(int status);
#endif
