#include "pty_support.h"

#include <stdlib.h>      // setenv
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
        // Child: this app IS the terminal emulator, so it must define the terminal
        // it presents instead of laundering whatever env it was launched with. An
        // app started outside a terminal (Finder, `open`, Xcode) has no TERM at
        // all, which silently disables zsh's line editor (backspace echoes as a
        // literal byte) and strips color from every capability-checking CLI.
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        // Same Finder-launch hole for locale: no LANG means "C" (multibyte off),
        // which garbles every TUI's box-drawing. Respect an inherited locale.
        if (getenv("LANG") == NULL) {
            setenv("LANG", "en_US.UTF-8", 1);
        }
        // forkpty copies EVERY descriptor the app holds into the child: other
        // cards' pty masters, the pipes of whatever git/ssh helper is running.
        // A child that keeps a pipe's write end open means the app's read never
        // sees EOF (the test suite deadlocked exactly there), and a sibling
        // holding a card's master keeps that card's child from ever seeing a
        // hangup. The child gets its terminal and nothing else.
        for (int fd = 3; fd < getdtablesize(); fd++) {
            close(fd);
        }
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
