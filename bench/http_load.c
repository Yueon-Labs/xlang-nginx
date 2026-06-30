// http_load.c — keepalive HTTP file-serving load generator.
//   http_load <port> <path> <total_requests> <concurrency>
// Each of <concurrency> processes opens ONE keepalive connection and fires
// <total/concurrency> GET <path> requests, reading each FULL response (parses
// Content-Length, drains the body) and counting successes. Reports req/s.
// Multiprocess (all cores, no GIL). For benchmarking file-serving throughput.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <time.h>
#include <sys/wait.h>

/* read one full HTTP response; return 1 if headers + full body were received.
 * Uses a static buffer (avoid stack garbage), null-terminates after each recv
 * so strstr is bounded, and drains exactly Content-Length body bytes. */
static int read_response(int s) {
    static char buf[32768];
    long hlen = 0;
    char *eoh = NULL;
    while (!eoh) {
        if (hlen >= 32760) return 0;
        ssize_t r = recv(s, buf + hlen, (size_t)(32760 - hlen), 0);
        if (r <= 0) return 0;
        hlen += r;
        buf[hlen] = 0;
        eoh = strstr(buf, "\r\n\r\n");
    }
    long clen = 0;
    char *p = strstr(buf, "Content-Length:");
    if (p) clen = atol(p + 15);
    long body_start = (long)(eoh - buf) + 4;
    long body_have = hlen - body_start; /* body bytes already buffered */
    long need = clen - body_have;
    while (need > 0) {
        ssize_t r = recv(s, buf, (size_t)(need > 32768 ? 32768 : need), 0);
        if (r <= 0) return 0;
        need -= r;
    }
    return 1;
}

static void run_child(int port, const char *path, long n, int id) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) _exit(255);
    struct sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    if (connect(s, (struct sockaddr*)&a, sizeof(a)) < 0) _exit(255);

    char req[512];
    snprintf(req, sizeof(req),
             "GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n", path);
    size_t reqlen = strlen(req);
    long done = 0;
    for (long i = 0; i < n; i++) {
        if (send(s, req, reqlen, 0) <= 0) break;
        if (!read_response(s)) break;
        done++;
    }
    close(s);
    char fn[64];
    snprintf(fn, sizeof(fn), "/tmp/hl_%d", id);
    FILE *f = fopen(fn, "w");
    if (f) { fprintf(f, "%ld\n", done); fclose(f); }
    _exit(0);
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <port> <path> <total_requests> <concurrency>\n", argv[0]);
        return 2;
    }
    int port = atoi(argv[1]);
    const char *path = argv[2];
    long total = atol(argv[3]);
    int conc = atoi(argv[4]);
    long per = total / conc;
    if (per < 1) per = 1;

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < conc; i++) {
        pid_t p = fork();
        if (p == 0) run_child(port, path, per, i);
    }
    for (int i = 0; i < conc; i++) {
        int st = 0;
        wait(&st);
    }
    long sum = 0;
    for (int i = 0; i < conc; i++) {
        char fn[64];
        snprintf(fn, sizeof(fn), "/tmp/hl_%d", i);
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
    fprintf(stderr, "req/s=%.0f  ok=%ld  time=%.3fs  conc=%d  port=%d  path=%s\n",
            dt > 0 ? sum / dt : 0, sum, dt, conc, port, path);
    return 0;
}
