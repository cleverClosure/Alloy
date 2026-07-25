/*
 * LaunchServices-aware Wine test launcher for GFX-001 title captures.
 * Author: Timur Isaev
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    const char *wine = getenv("ALLOY_WINE_BINARY");
    const char *snapshot = getenv("ALLOY_POLICY_SNAPSHOT_PATH");
    const char *log_path = getenv("ALLOY_LAUNCH_LOG_PATH");
    int snapshot_fd;

    if (log_path && *log_path)
    {
        int log_fd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (log_fd < 0 || dup2(log_fd, STDOUT_FILENO) < 0 || dup2(log_fd, STDERR_FILENO) < 0)
        {
            fprintf(stderr, "cannot open launch log: %s\n", strerror(errno));
            if (log_fd >= 0)
                close(log_fd);
            return 2;
        }
        if (log_fd != STDOUT_FILENO && log_fd != STDERR_FILENO)
            close(log_fd);
    }

    if (!wine || !*wine || !snapshot || !*snapshot)
    {
        fprintf(stderr, "ALLOY_WINE_BINARY and ALLOY_POLICY_SNAPSHOT_PATH are required\n");
        return 2;
    }
    if (argc < 2)
    {
        fprintf(stderr, "a Windows executable is required\n");
        return 2;
    }

    snapshot_fd = open(snapshot, O_RDONLY);
    if (snapshot_fd < 0)
    {
        fprintf(stderr, "cannot open policy snapshot: %s\n", strerror(errno));
        return 2;
    }
    if (snapshot_fd != 9)
    {
        if (dup2(snapshot_fd, 9) < 0)
        {
            fprintf(stderr, "cannot assign policy fd: %s\n", strerror(errno));
            close(snapshot_fd);
            return 2;
        }
        close(snapshot_fd);
    }
    if (fcntl(9, F_SETFD, 0) < 0 || setenv("ALLOY_POLICY_SNAPSHOT_FD", "9", 1) < 0)
    {
        fprintf(stderr, "cannot prepare policy fd: %s\n", strerror(errno));
        close(9);
        return 2;
    }

    argv[0] = (char *)wine;
    execv(wine, argv);
    fprintf(stderr, "cannot execute Wine: %s\n", strerror(errno));
    return 2;
}
