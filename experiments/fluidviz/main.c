#define _POSIX_C_SOURCE 200809L
#include "fluid.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if !defined(_WIN32)
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#endif

#ifdef _OPENMP
#include <omp.h>
#endif

/* Choose a thread count that keeps enough work per thread. Below ~64 rows per
 * thread the red-black solver's fork/join + false-sharing overhead outweighs
 * the parallel win (measured: 16 threads on a 256 grid is slower than 1). */
static void tune_threads(int N) {
#ifdef _OPENMP
    int want = N / 64;
    if (want < 1) want = 1;
    int have = omp_get_max_threads();
    if (want > have) want = have;
    omp_set_num_threads(want);
#else
    (void)N;
#endif
}

/* ------------------------------------------------------------------ */
/* Timing                                                              */
/* ------------------------------------------------------------------ */

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void sleep_sec(double s) {
    if (s <= 0) return;
    struct timespec ts;
    ts.tv_sec = (time_t)s;
    ts.tv_nsec = (long)((s - (double)ts.tv_sec) * 1e9);
    nanosleep(&ts, NULL);
}

/* ------------------------------------------------------------------ */
/* Colour map (inferno-ish): 0..1 density -> RGB                        */
/* ------------------------------------------------------------------ */

static void colormap(float t, uint8_t *r, uint8_t *g, uint8_t *b) {
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    /* Piecewise gradient: black -> purple -> orange -> yellow -> white. */
    static const float stops[][4] = {
        {0.00f, 0.00f, 0.00f, 0.00f},
        {0.20f, 0.25f, 0.02f, 0.28f},
        {0.45f, 0.72f, 0.12f, 0.20f},
        {0.70f, 0.98f, 0.55f, 0.04f},
        {0.90f, 1.00f, 0.87f, 0.30f},
        {1.00f, 1.00f, 1.00f, 0.95f},
    };
    int n = (int)(sizeof(stops) / sizeof(stops[0]));
    int i = 0;
    while (i < n - 1 && t > stops[i + 1][0]) i++;
    float lo = stops[i][0], hi = stops[i + 1][0];
    float f = (hi > lo) ? (t - lo) / (hi - lo) : 0.0f;
    float rr = stops[i][1] + f * (stops[i + 1][1] - stops[i][1]);
    float gg = stops[i][2] + f * (stops[i + 1][2] - stops[i][2]);
    float bb = stops[i][3] + f * (stops[i + 1][3] - stops[i][3]);
    *r = (uint8_t)(rr * 255.0f + 0.5f);
    *g = (uint8_t)(gg * 255.0f + 0.5f);
    *b = (uint8_t)(bb * 255.0f + 0.5f);
}

/* ------------------------------------------------------------------ */
/* Terminal raw mode                                                   */
/* ------------------------------------------------------------------ */

#if !defined(_WIN32)
static struct termios g_saved_term;
static int g_raw_active = 0;

static void term_restore(void) {
    if (g_raw_active) {
        tcsetattr(STDIN_FILENO, TCSANOW, &g_saved_term);
        g_raw_active = 0;
    }
    printf("\x1b[?25h\x1b[0m\x1b[?1049l"); /* show cursor, reset, leave alt screen */
    fflush(stdout);
}

static void term_raw(void) {
    if (!isatty(STDIN_FILENO)) return;
    tcgetattr(STDIN_FILENO, &g_saved_term);
    struct termios t = g_saved_term;
    t.c_lflag &= ~(unsigned)(ICANON | ECHO);
    t.c_cc[VMIN] = 0;
    t.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &t);
    g_raw_active = 1;
    atexit(term_restore);
    printf("\x1b[?1049h\x1b[?25l\x1b[2J"); /* alt screen, hide cursor, clear */
}

static int term_size(int *cols, int *rows) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
        *cols = ws.ws_col;
        *rows = ws.ws_row;
        return 1;
    }
    return 0;
}

static int read_key(void) {
    unsigned char c;
    if (read(STDIN_FILENO, &c, 1) == 1) return c;
    return -1;
}
#endif

/* ------------------------------------------------------------------ */
/* Rendering: half-block pixels, one output buffer per frame           */
/* ------------------------------------------------------------------ */

typedef struct {
    char  *buf;
    size_t len, cap;
} Sbuf;

static void sb_reserve(Sbuf *s, size_t extra) {
    if (s->len + extra <= s->cap) return;
    size_t cap = s->cap ? s->cap : 4096;
    while (cap < s->len + extra) cap *= 2;
    s->buf = realloc(s->buf, cap);
    s->cap = cap;
}

static void sb_puts(Sbuf *s, const char *str) {
    size_t n = strlen(str);
    sb_reserve(s, n);
    memcpy(s->buf + s->len, str, n);
    s->len += n;
}

static void sb_append(Sbuf *s, const char *data, size_t n) {
    sb_reserve(s, n);
    memcpy(s->buf + s->len, data, n);
    s->len += n;
}

/* Sample fluid density at pixel (px,py) in a WxH pixel grid. */
static float sample(const Fluid *f, int px, int py, int W, int H) {
    int gx = 1 + (int)((long)px * f->N / W);
    int gy = 1 + (int)((long)py * f->N / H);
    if (gx > f->N) gx = f->N;
    if (gy > f->N) gy = f->N;
    return f->d[fluid_ix(f, gx, gy)];
}

/* Render the density field into `sb`. cols x rows char cells -> cols x 2*rows
 * pixels via the upper-half-block glyph. */
static void render(Sbuf *sb, const Fluid *f, int cols, int rows) {
    const int W = cols;
    const int H = rows * 2;
    sb->len = 0;
    sb_puts(sb, "\x1b[H"); /* cursor home */

    /* Auto-exposure: injection deposits density far above 1, so without
     * normalisation every active cell clamps straight to white and the
     * colormap gradient never shows. Normalise by a peak density eased over
     * frames (flicker-free), then gamma-lift so mid densities land in the
     * colours instead of at the extremes. */
    static float disp_max = 1.0f;
    float peak = 0.0f;
    for (size_t i = 0; i < f->cells; i++)
        if (f->d[i] > peak) peak = f->d[i];
    if (peak < 1e-3f) peak = 1e-3f;
    disp_max = disp_max * 0.9f + peak * 0.1f;
    const float inv = 1.0f / disp_max;

    int last_fr = -1, last_fg = -1, last_fb = -1;
    int last_br = -1, last_bg = -1, last_bb = -1;
    char tmp[64];

    for (int cy = 0; cy < rows; cy++) {
        for (int cx = 0; cx < cols; cx++) {
            float dt = sample(f, cx, cy * 2, W, H) * inv;     /* top -> fg */
            float db = sample(f, cx, cy * 2 + 1, W, H) * inv; /* bottom -> bg */
            dt = sqrtf(dt < 0.0f ? 0.0f : dt); /* gamma 0.5: lift midtones */
            db = sqrtf(db < 0.0f ? 0.0f : db);
            uint8_t fr, fg, fb, br, bg, bb;
            colormap(dt, &fr, &fg, &fb);
            colormap(db, &br, &bg, &bb);

            if (fr != last_fr || fg != last_fg || fb != last_fb) {
                int n = snprintf(tmp, sizeof(tmp), "\x1b[38;2;%d;%d;%dm", fr, fg, fb);
                sb_append(sb, tmp, (size_t)n);
                last_fr = fr; last_fg = fg; last_fb = fb;
            }
            if (br != last_br || bg != last_bg || bb != last_bb) {
                int n = snprintf(tmp, sizeof(tmp), "\x1b[48;2;%d;%d;%dm", br, bg, bb);
                sb_append(sb, tmp, (size_t)n);
                last_br = br; last_bg = bg; last_bb = bb;
            }
            sb_puts(sb, "\xe2\x96\x80"); /* U+2580 UPPER HALF BLOCK */
        }
        sb_puts(sb, "\x1b[0m");
        last_fr = last_fg = last_fb = -1;
        last_br = last_bg = last_bb = -1;
        if (cy != rows - 1) sb_puts(sb, "\r\n");
    }
}

/* ------------------------------------------------------------------ */
/* Self-driving emitters: a few orbiting jets that keep the field alive */
/* ------------------------------------------------------------------ */

static void inject(Fluid *f, double t) {
    const int N = f->N;
    const int njets = 3;
    for (int k = 0; k < njets; k++) {
        double phase = t * (0.6 + 0.25 * k) + k * 2.09439510239; /* 2pi/3 */
        double cx = 0.5 + 0.34 * cos(phase * 0.7);
        double cy = 0.5 + 0.34 * sin(phase * 1.1);
        int gx = 1 + (int)(cx * (N - 1));
        int gy = 1 + (int)(cy * (N - 1));

        float ang = (float)(phase * 2.3);
        float fx = 90.0f * cosf(ang);
        float fy = 90.0f * sinf(ang);

        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                int x = gx + dx, y = gy + dy;
                if (x < 1 || y < 1 || x > N || y > N) continue;
                fluid_add_density(f, x, y, 120.0f);
                fluid_add_velocity(f, x, y, fx, fy);
            }
        }
    }
}

/* ------------------------------------------------------------------ */

static void print_help(const char *prog) {
    printf("usage: %s [--n GRID] [--fps F] [--bench STEPS]\n", prog);
    printf("  --n GRID     interior grid resolution (default 128)\n");
    printf("  --fps F      target frames per second (default 60)\n");
    printf("  --bench N    run N steps headless, print throughput, exit\n");
    printf("  keys: q / ESC to quit\n");
}

int main(int argc, char **argv) {
    int   N = 128;
    double target_fps = 60.0;
    long  bench = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--n") && i + 1 < argc) {
            N = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--fps") && i + 1 < argc) {
            target_fps = atof(argv[++i]);
        } else if (!strcmp(argv[i], "--bench") && i + 1 < argc) {
            bench = atol(argv[++i]);
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            print_help(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "unknown arg: %s\n", argv[i]);
            print_help(argv[0]);
            return 2;
        }
    }
    if (N < 8) N = 8;
    tune_threads(N);

    Fluid *f = fluid_create(N, 0.10f, 0.00001f, 0.00001f);
    if (!f) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }

    /* Headless benchmark path: no terminal, no rendering. */
    if (bench > 0) {
        double t0 = now_sec();
        for (long i = 0; i < bench; i++) {
            inject(f, (double)i * 0.03);
            fluid_step(f);
        }
        double dt = now_sec() - t0;
        double sps = (double)bench / dt;
        printf("grid=%dx%d steps=%ld time=%.3fs  %.1f steps/s  %.2f ms/step\n",
               N, N, bench, dt, sps, 1000.0 * dt / (double)bench);
        /* sanity: field must contain finite, non-zero density */
        double sum = 0;
        for (size_t i = 0; i < f->cells; i++) sum += f->d[i];
        printf("density integral=%.3f (finite=%s)\n", sum,
               isfinite(sum) ? "yes" : "NO");
        fluid_destroy(f);
        return isfinite(sum) ? 0 : 1;
    }

#if defined(_WIN32)
    fprintf(stderr, "interactive mode needs a POSIX terminal; use --bench\n");
    fluid_destroy(f);
    return 1;
#else
    int cols = 80, rows = 24;
    term_size(&cols, &rows);
    term_raw();

    Sbuf sb = {0};
    double frame_budget = 1.0 / target_fps;
    double sim_t = 0.0;
    double fps = 0.0;
    long   frame = 0;
    int    running = 1;

    while (running) {
        double t_start = now_sec();

        int c;
        while ((c = read_key()) != -1) {
            if (c == 'q' || c == 27) running = 0;
        }

        /* handle resize each frame (cheap) */
        term_size(&cols, &rows);
        if (rows < 2) rows = 2;

        inject(f, sim_t);
        fluid_step(f);
        sim_t += 0.03;

        render(&sb, f, cols, rows - 1);

        /* status line */
        char status[160];
        int n = snprintf(status, sizeof(status),
                         "\x1b[0m\r\n\x1b[7m fluidviz  grid %dx%d  %dx%d px  "
                         "%.0f fps  frame %ld  [q]uit \x1b[0m\x1b[K",
                         N, N, cols, (rows - 1) * 2, fps, frame);
        sb_append(&sb, status, (size_t)n);

        fwrite(sb.buf, 1, sb.len, stdout);
        fflush(stdout);

        frame++;
        double elapsed = now_sec() - t_start;
        double inst = elapsed > 0 ? 1.0 / elapsed : target_fps;
        fps = fps == 0 ? inst : fps * 0.9 + inst * 0.1;
        sleep_sec(frame_budget - elapsed);
    }

    free(sb.buf);
    term_restore();
    fluid_destroy(f);
    return 0;
#endif
}
