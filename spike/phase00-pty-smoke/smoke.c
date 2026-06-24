// Phase 00 spike — in-process PTY read via libghostty-vt (no screen-scrape).
//
// Proves the load-bearing US-004 capability: spawn a real process in a pty,
// read its output IN-PROCESS, feed the bytes through libghostty-vt's terminal
// emulator, and read the resulting screen state back as plain text. No
// AppleScript, no GUI, no screen scraping.
//
// Verdict: prints "GO" and exits 0 if the screen contains the expected line;
// "NO-GO" and exits 1 otherwise. Build/link failure is its own NO-GO signal.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>

#if defined(__APPLE__)
#include <util.h>   // forkpty() on macOS
#else
#include <pty.h>    // forkpty() on Linux
#endif

#include <ghostty/vt.h>

// Spawn argv in a fresh pty. Returns the master fd; stores the child pid.
static int spawn_in_pty(char *const argv[], pid_t *child_out) {
    struct winsize ws = {.ws_row = 24, .ws_col = 80};
    int master;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        perror("forkpty");
        return -1;
    }
    if (pid == 0) {
        execvp(argv[0], argv);
        perror("execvp");
        _exit(127);
    }
    *child_out = pid;
    return master;
}

// Drain the master fd to EOF, feeding every byte into the terminal in-process.
// Returns total bytes read. Handles both Linux (read==0) and macOS (EIO) EOF.
static size_t drain_into_terminal(int master, GhosttyTerminal term) {
    uint8_t buf[4096];
    size_t total = 0;
    for (;;) {
        ssize_t n = read(master, buf, sizeof(buf));
        if (n > 0) {
            ghostty_terminal_vt_write(term, buf, (size_t)n);
            total += (size_t)n;
            continue;
        }
        if (n == 0) break;          // Linux: slave closed
        if (errno == EINTR) continue;
        if (errno == EIO) break;    // macOS: slave closed
        perror("read");
        break;
    }
    return total;
}

// Format the terminal's active screen as trimmed plain text (NUL-terminated).
// Caller frees the returned buffer.
static char *screen_to_text(GhosttyTerminal term) {
    GhosttyFormatterTerminalOptions opts =
        GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    opts.trim = true;

    GhosttyFormatter fmt;
    if (ghostty_formatter_terminal_new(NULL, &fmt, term, opts) != GHOSTTY_SUCCESS)
        return NULL;

    uint8_t *buf = NULL;
    size_t len = 0;
    GhosttyResult r = ghostty_formatter_format_alloc(fmt, NULL, &buf, &len);
    ghostty_formatter_free(fmt);
    if (r != GHOSTTY_SUCCESS)
        return NULL;

    char *text = malloc(len + 1);
    if (text) {
        memcpy(text, buf, len);
        text[len] = '\0';
    }
    ghostty_free(NULL, buf, len);
    return text;
}

int main(void) {
    const char *needle = "hello-ghostty";

    GhosttyTerminal term;
    GhosttyTerminalOptions topts = {.cols = 80, .rows = 24, .max_scrollback = 1000};
    if (ghostty_terminal_new(NULL, &term, topts) != GHOSTTY_SUCCESS) {
        fprintf(stderr, "NO-GO: ghostty_terminal_new failed\n");
        return 2;
    }

    char *argv[] = {"/bin/echo", (char *)needle, NULL};
    pid_t child;
    int master = spawn_in_pty(argv, &child);
    if (master < 0) {
        fprintf(stderr, "NO-GO: forkpty failed\n");
        ghostty_terminal_free(term);
        return 2;
    }

    size_t got = drain_into_terminal(master, term);
    int status = 0;
    waitpid(child, &status, 0);
    close(master);

    char *text = screen_to_text(term);
    if (!text) {
        fprintf(stderr, "NO-GO: formatter failed\n");
        ghostty_terminal_free(term);
        return 2;
    }

    int found = strstr(text, needle) != NULL;
    printf("---- in-process PTY read: %zu bytes ----\n", got);
    printf("---- libghostty screen (plain text) ----\n%s\n", text);
    printf("----------------------------------------\n");
    printf("%s: screen %s \"%s\"\n",
           found ? "GO" : "NO-GO",
           found ? "contains" : "does NOT contain",
           needle);

    free(text);
    ghostty_terminal_free(term);
    return found ? 0 : 1;
}
