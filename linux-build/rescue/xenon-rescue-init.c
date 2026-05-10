#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static void say(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fflush(stdout);
}

static void ensure_dir(const char *path, mode_t mode)
{
    if (mkdir(path, mode) == 0 || errno == EEXIST) {
        chmod(path, mode);
    }
}

static void mount_basic_fs(void)
{
    mount(NULL, "/", NULL, MS_REMOUNT, NULL);

    ensure_dir("/proc", 0555);
    ensure_dir("/sys", 0555);
    ensure_dir("/dev", 0755);
    ensure_dir("/dev/pts", 0755);
    ensure_dir("/run", 0755);
    ensure_dir("/tmp", 01777);

    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mount("devpts", "/dev/pts", "devpts", 0, NULL);
    mount("tmpfs", "/run", "tmpfs", 0, "mode=0755");
}

static void setup_console(void)
{
    int fd = open("/dev/console", O_RDWR | O_NOCTTY);

    if (fd < 0) {
        fd = open("/dev/tty0", O_RDWR | O_NOCTTY);
    }
    if (fd < 0) {
        fd = open("/dev/null", O_RDWR);
    }
    if (fd >= 0) {
        dup2(fd, STDIN_FILENO);
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        if (fd > STDERR_FILENO) {
            close(fd);
        }
    }
}

static void reap_children(int sig)
{
    (void)sig;
    while (waitpid(-1, NULL, WNOHANG) > 0) {
    }
}

static void run_program(char *const argv[])
{
    pid_t pid = fork();
    int status = 0;

    if (pid < 0) {
        say("fork failed: %s\n", strerror(errno));
        return;
    }
    if (pid == 0) {
        execv(argv[0], argv);
        fprintf(stderr, "exec %s failed: %s\n", argv[0], strerror(errno));
        _exit(127);
    }

    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }

    if (WIFSIGNALED(status)) {
        say("%s exited from signal %d\n", argv[0], WTERMSIG(status));
    } else if (WIFEXITED(status)) {
        say("%s exited with status %d\n", argv[0], WEXITSTATUS(status));
    }
}

static void cmd_ls(const char *path)
{
    DIR *dir = opendir(path && *path ? path : ".");
    struct dirent *de;

    if (!dir) {
        say("ls: %s: %s\n", path, strerror(errno));
        return;
    }

    while ((de = readdir(dir)) != NULL) {
        say("%s\n", de->d_name);
    }
    closedir(dir);
}

static void cmd_cat(const char *path)
{
    char buf[1024];
    ssize_t n;
    int fd;

    if (!path || !*path) {
        say("usage: cat <file>\n");
        return;
    }

    fd = open(path, O_RDONLY);
    if (fd < 0) {
        say("cat: %s: %s\n", path, strerror(errno));
        return;
    }
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        fwrite(buf, 1, (size_t)n, stdout);
    }
    close(fd);
    fflush(stdout);
}

static char *next_arg(char **cursor)
{
    char *arg = *cursor;

    while (*arg == ' ' || *arg == '\t') {
        arg++;
    }
    if (*arg == '\0') {
        *cursor = arg;
        return NULL;
    }
    *cursor = arg;
    while (**cursor && **cursor != ' ' && **cursor != '\t' && **cursor != '\n') {
        (*cursor)++;
    }
    if (**cursor) {
        **cursor = '\0';
        (*cursor)++;
    }
    return arg;
}

static void print_help(void)
{
    say("Commands:\n");
    say("  help                 show this help\n");
    say("  mounts               remount / and mount proc/sys/dev/run\n");
    say("  ls [dir]             list a directory\n");
    say("  cat <file>           print a file\n");
    say("  sh                   try /bin/bash -l as a child\n");
    say("  systemd              exec /sbin/init as PID 1\n");
    say("  reboot               reboot the console\n");
    say("  poweroff             power off the console\n");
}

int main(void)
{
    char line[512];

    signal(SIGCHLD, reap_children);
    mount_basic_fs();
    setup_console();
    sethostname("xenon360", 8);

    say("\nXenon native rescue init is running as PID 1.\n");
    say("This binary is built by the Xenon cross-toolchain, not ArchPOWER userland.\n");
    print_help();

    for (;;) {
        char *cursor = line;
        char *cmd;

        say("\nxenon-rescue# ");
        if (!fgets(line, sizeof(line), stdin)) {
            clearerr(stdin);
            sleep(1);
            continue;
        }

        cmd = next_arg(&cursor);
        if (!cmd) {
            continue;
        }

        if (strcmp(cmd, "help") == 0) {
            print_help();
        } else if (strcmp(cmd, "mounts") == 0) {
            mount_basic_fs();
        } else if (strcmp(cmd, "ls") == 0) {
            char *path = next_arg(&cursor);
            cmd_ls(path ? path : ".");
        } else if (strcmp(cmd, "cat") == 0) {
            cmd_cat(next_arg(&cursor));
        } else if (strcmp(cmd, "sh") == 0) {
            char *argv[] = { "/bin/bash", "-l", NULL };
            run_program(argv);
        } else if (strcmp(cmd, "systemd") == 0) {
            say("Executing /sbin/init as PID 1...\n");
            execl("/sbin/init", "/sbin/init", (char *)NULL);
            say("exec /sbin/init failed: %s\n", strerror(errno));
        } else if (strcmp(cmd, "reboot") == 0) {
            sync();
            reboot(RB_AUTOBOOT);
        } else if (strcmp(cmd, "poweroff") == 0) {
            sync();
            reboot(RB_POWER_OFF);
        } else {
            say("unknown command: %s\n", cmd);
            print_help();
        }
    }
}
