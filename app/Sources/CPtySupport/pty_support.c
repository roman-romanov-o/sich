#include "pty_support.h"

#include <unistd.h>
#include <sys/ioctl.h>   // TIOCSWINSZ

#if defined(__APPLE__)
#include <util.h>   // forkpty() on macOS
#else
#include <pty.h>    // forkpty() on Linux
#endif

int gl_spawn_in_pty(char *const argv[],
                    unsigned short rows,
                    unsigned short cols,
                    pid_t *child_out) {
    struct winsize ws = {.ws_row = rows, .ws_col = cols};
    int master;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        // Child: only async-signal-safe calls until exec.
        execvp(argv[0], argv);
        _exit(127);  // exec failed
    }
    *child_out = pid;
    return master;
}

int gl_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws = {.ws_row = rows, .ws_col = cols};
    return ioctl(fd, TIOCSWINSZ, &ws);
}
