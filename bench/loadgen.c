// loadgen.c — C HTTP load generator (wrk substitute, no GIL).
//   loadgen <port> <total_requests> <concurrency_processes>
// Forks <concurrency> processes; each opens ONE keepalive connection and fires
// <total/concurrency> GET requests, counting fully-received 5-byte "hello"
// bodies. Parent times the wall clock across all concurrent children and
// reports req/s. Multiprocess = uses all cores, no interpreter overhead.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <time.h>
#include <sys/wait.h>
#include <errno.h>

static const char *REQ = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";

/* child: fire `n` keepalive requests; exit code = count completed (0..254) or
 * 255 on connect failure. For counts > 254 we write the real count to a file. */
static int run_child(int port, long n, int id) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) _exit(255);
    struct sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    if (connect(s, (struct sockaddr*)&a, sizeof(a)) < 0) _exit(255);

    char buf[8192];
    long done = 0;
    for (long i = 0; i < n; i++) {
        if (send(s, REQ, strlen(REQ), 0) <= 0) break;
        long got = 0;
        /* read until we have the 5-byte "hello" body for this response */
        while (got < 5) {
            ssize_t r = recv(s, buf + got, (size_t)(8191 - got), 0);
            if (r <= 0) goto done;
            got += r;
            /* look for end of this response's body */
            char *p = strstr(buf, "hello");
            if (p) {
                /* shift remainder past this response */
                long consumed = (long)(p - buf) + 5;
                memmove(buf, buf + consumed, (size_t)(got - consumed));
                got -= consumed;
                done++;
                break;
            }
        }
    }
done:
    close(s);
    /* write real count to per-child file so parent can sum >255 */
    char fn[64];
    snprintf(fn, sizeof(fn), "/tmp/lg_%d", id);
    FILE *f = fopen(fn, "w");
    if (f) { fprintf(f, "%ld\n", done); fclose(f); }
    _exit(done >= 254 ? 254 : (int)done);
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <port> <total_requests> <concurrency>\n", argv[0]);
        return 2;
    }
    int port = atoi(argv[1]);
    long total = atol(argv[2]);
    int conc = atoi(argv[3]);
    long per = total / conc;
    if (per < 1) per = 1;

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    for (int i = 0; i < conc; i++) {
        pid_t p = fork();
        if (p == 0) run_child(port, per, i);
    }

    long sum = 0;
    /* wait for ALL children (exit order is arbitrary, so don't tie id to wait order) */
    for (int i = 0; i < conc; i++) {
        int st = 0;
        wait(&st);
    }
    /* sum each child's count file by its fork index */
    for (int i = 0; i < conc; i++) {
        char fn[64];
        snprintf(fn, sizeof(fn), "/tmp/lg_%d", i);
        FILE *f = fopen(fn, "r");
        if (f) {
            long c = 0;
            if (fscanf(f, "%ld", &c) == 1) sum += c;
            fclose(f);
            remove(fn);
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double dt = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    fprintf(stderr, "req/s=%.0f  ok=%ld  time=%.3fs  conc=%d  port=%d\n",
            dt > 0 ? sum / dt : 0, sum, dt, conc, port);
    return 0;
}
