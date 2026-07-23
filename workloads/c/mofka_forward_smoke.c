/*
 * mofka_forward_smoke.c -- the C workload for Darshan -> Mofka. Models an ML
 * training run:
 *   - a POSIX training log: open once, one write() per EPOCH, then close
 *   - an STDIO checkpoint file every CHECKPOINT_EVERY epochs (fopen/fwrite/fclose)
 *
 * The connector emits one event per instrumented I/O call, so the event count is
 * known ahead of time (the point of the two knobs -- no time knob):
 *   POSIX events = epochs + 2                         (open + epochs writes + close)
 *   STDIO events = 3 * (epochs / checkpoint_every)    (each ckpt: fopen+fwrite+fclose)
 *   TOTAL        = (epochs + 2) + 3*(epochs / checkpoint_every)
 * The program prints this estimate at startup.
 *
 * Knobs come from the env vars EPOCHS / CHECKPOINT_EVERY, which job.sh derives from
 * the single config file (workloads/workload.config); built-in defaults apply when
 * run standalone. argv[1] = scratch dir for the I/O files.
 *
 * Build: cc -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke
 * Run under LD_PRELOAD=libdarshan.so with DARSHAN_MOFKA_ENABLE=1 + a live group file.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

static void die(const char* m) { perror(m); exit(1); }

/* return 1 and set *out if env var k holds a number */
static int env_long(const char* k, long* out)
{
    const char* v = getenv(k);
    if (!v || !*v) return 0;
    *out = atol(v);
    return 1;
}

int main(int argc, char** argv)
{
    const char* dir = (argc > 1) ? argv[1] : "/tmp/dm-cworkload";

    /* knobs come from EPOCHS / CHECKPOINT_EVERY, which job.sh derives from the one
       config file (workloads/workload.config); built-in defaults for standalone use. */
    long epochs, ckpt;
    if (!env_long("EPOCHS", &epochs)) epochs = 8;
    if (!env_long("CHECKPOINT_EVERY", &ckpt)) ckpt = 4;
    if (epochs < 1) epochs = 1;
    if (ckpt   < 1) ckpt   = 1;

    long num_ckpt = epochs / ckpt;
    long posix_ev = epochs + 2;
    long stdio_ev = 3 * num_ckpt;
    printf("C workload: epochs=%ld checkpoint_every=%ld -> POSIX~%ld STDIO~%ld TOTAL~%ld events\n",
           epochs, ckpt, posix_ev, stdio_ev, posix_ev + stdio_ev);

    if (mkdir(dir, 0755) != 0 && errno != EEXIST) die("mkdir");

    char trainlog[600], ckpt_path[600];
    char buf[64];
    memset(buf, 'x', sizeof buf);
    snprintf(trainlog, sizeof trainlog, "%s/train.log", dir);

    int fd = open(trainlog, O_CREAT | O_TRUNC | O_WRONLY, 0644);   /* 1 POSIX open */
    if (fd < 0) die("open train.log");
    for (long e = 1; e <= epochs; e++) {
        if (write(fd, buf, sizeof buf) != (ssize_t)sizeof buf) die("write");  /* 1 POSIX write / epoch */
        if (e % ckpt == 0) {                                        /* checkpoint via STDIO */
            snprintf(ckpt_path, sizeof ckpt_path, "%s/ckpt_%ld.dat", dir, e / ckpt);
            FILE* cf = fopen(ckpt_path, "w");                       /* fopen  */
            if (!cf) die("fopen ckpt");
            if (fwrite(buf, 1, sizeof buf, cf) != sizeof buf) die("fwrite ckpt");  /* fwrite */
            if (fclose(cf) != 0) die("fclose ckpt");               /* fclose */
            unlink(ckpt_path);
        }
    }
    if (close(fd) != 0) die("close");                              /* 1 POSIX close */
    unlink(trainlog);

    printf("C workload complete: %ld epochs, %ld checkpoints in %s\n", epochs, num_ckpt, dir);
    return 0;
}
