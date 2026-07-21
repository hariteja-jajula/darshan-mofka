/*
 * mofka_forward_smoke.c -- tiny manual smoke workload for Darshan -> Mofka.
 *
 * This program does only local C file I/O. To test the connector, compile it and
 * run it under LD_PRELOAD=libdarshan.so with DARSHAN_MOFKA_ENABLE=1 and a live
 * Mofka group file. It intentionally does not know anything about Mofka itself.
 *
 * Build:
 *   cc -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke
 *
 * Run shape:
 *   env DARSHAN_ENABLE_NONMPI=1 DARSHAN_MOFKA_ENABLE=1 ... \
 *       LD_PRELOAD=/path/to/libdarshan.so ./workloads/c/mofka_forward_smoke /tmp/smoke-dir
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

static void die(const char* msg)
{
    perror(msg);
    exit(1);
}

int main(int argc, char** argv)
{
    const char* dir = (argc > 1) ? argv[1] : "/tmp";
    char posix_path[512];
    char stdio_path[512];
    char buf[64];

    if (mkdir(dir, 0755) != 0 && errno != EEXIST)
        die("mkdir");

    snprintf(posix_path, sizeof(posix_path), "%s/posix-smoke.dat", dir);
    snprintf(stdio_path, sizeof(stdio_path), "%s/stdio-smoke.dat", dir);

    int fd = open(posix_path, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0) die("open posix");
    if (write(fd, "darshan-posix-smoke\n", 20) != 20) die("write posix");
    if (fsync(fd) != 0) die("fsync posix");
    if (lseek(fd, 0, SEEK_SET) < 0) die("lseek posix");
    if (read(fd, buf, sizeof(buf)) < 0) die("read posix");
    if (close(fd) != 0) die("close posix");

    FILE* fp = fopen(stdio_path, "w+");
    if (!fp) die("fopen stdio");
    if (fwrite("darshan-stdio-smoke\n", 1, 20, fp) != 20) die("fwrite stdio");
    if (fflush(fp) != 0) die("fflush stdio");
    if (fseek(fp, 0, SEEK_SET) != 0) die("fseek stdio");
    if (fread(buf, 1, sizeof(buf), fp) == 0 && ferror(fp)) die("fread stdio");
    if (fclose(fp) != 0) die("fclose stdio");

    unlink(posix_path);
    unlink(stdio_path);

    printf("mofka_forward_smoke complete: wrote/read POSIX and STDIO files in %s\n", dir);
    return 0;
}
