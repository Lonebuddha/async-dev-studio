#include "PTYSupport.h"
#include <util.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

pid_t studio_pty_spawn(const char *executable, char *const argv[], char *const envp[],
                      const char *directory, unsigned short columns, unsigned short rows,
                      int *master, int *exec_error) {
    // Close-on-exec pipe reports chdir/exec failure without relying on terminal output.
    int errors[2];
    if (pipe(errors) == -1) return -1;
    fcntl(errors[0], F_SETFD, FD_CLOEXEC);
    fcntl(errors[1], F_SETFD, FD_CLOEXEC);
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == -1) {
        int saved = errno; close(errors[0]); close(errors[1]); errno = saved; return -1;
    }
    if (pid == 0) {
        close(errors[0]);
        if (chdir(directory) == 0) execve(executable, argv, envp);
        int failure = errno;
        (void)write(errors[1], &failure, sizeof(failure));
        _exit(127);
    }
    close(errors[1]);
    int failure = 0;
    ssize_t received;
    do { received = read(errors[0], &failure, sizeof(failure)); } while (received == -1 && errno == EINTR);
    close(errors[0]);
    if (received > 0) {
        close(*master); *master = -1;
        while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {}
        *exec_error = failure;
        errno = failure;
        return -1;
    }
    fcntl(*master, F_SETFD, FD_CLOEXEC);
    *exec_error = 0;
    return pid;
}
int studio_pty_resize(int fd, unsigned short columns, unsigned short rows) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    return ioctl(fd, TIOCSWINSZ, &size);
}
int studio_process_exit_code(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}
