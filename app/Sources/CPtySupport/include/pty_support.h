#ifndef GHOSTLING_PTY_SUPPORT_H
#define GHOSTLING_PTY_SUPPORT_H

#include <sys/types.h>

/**
 * Spawn argv[0] in a fresh pty and return the master fd.
 *
 * The fork + execvp happen entirely in C so the child, in the window between
 * fork() and exec(), never touches the Swift runtime (async-signal-safety).
 * The caller owns the returned master fd and must close() it.
 *
 * @param argv      NULL-terminated argument vector; argv[0] is the program.
 * @param rows      Initial pty rows.
 * @param cols      Initial pty cols.
 * @param child_out Receives the child pid on success.
 * @return The master fd (>= 0) on success, or -1 if forkpty failed.
 */
int gl_spawn_in_pty(char *const argv[],
                    unsigned short rows,
                    unsigned short cols,
                    pid_t *child_out);

/**
 * Resize the pty's window size (TIOCSWINSZ). The kernel delivers SIGWINCH to the
 * child's foreground process group, so the child (shell, claude TUI) reflows to
 * the new geometry — the fix for a child stuck thinking it is 80x24.
 *
 * @param fd   The pty master fd.
 * @param rows New row count.
 * @param cols New column count.
 * @return 0 on success, -1 on ioctl failure.
 */
int gl_set_winsize(int fd, unsigned short rows, unsigned short cols);

#endif /* GHOSTLING_PTY_SUPPORT_H */
