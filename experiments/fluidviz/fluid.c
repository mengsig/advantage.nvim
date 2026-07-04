#include "fluid.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define IX(x, y) ((size_t)(x) + stride * (size_t)(y))

/* Gauss-Seidel relaxation iterations for the implicit solves. Higher is more
 * accurate but costs linearly; 12-20 is a good real-time trade-off. */
#ifndef FLUID_GS_ITERS
#define FLUID_GS_ITERS 16
#endif

static float *alloc_field(size_t cells) {
    float *p = calloc(cells, sizeof(float));
    return p;
}

Fluid *fluid_create(int N, float dt, float diff, float visc) {
    if (N < 2) return NULL;
    Fluid *f = calloc(1, sizeof(Fluid));
    if (!f) return NULL;

    f->N = N;
    f->stride = (size_t)N + 2;
    f->cells = f->stride * f->stride;
    f->dt = dt;
    f->diff = diff;
    f->visc = visc;

    f->u = alloc_field(f->cells);
    f->v = alloc_field(f->cells);
    f->u0 = alloc_field(f->cells);
    f->v0 = alloc_field(f->cells);
    f->d = alloc_field(f->cells);
    f->d0 = alloc_field(f->cells);

    if (!f->u || !f->v || !f->u0 || !f->v0 || !f->d || !f->d0) {
        fluid_destroy(f);
        return NULL;
    }
    return f;
}

void fluid_destroy(Fluid *f) {
    if (!f) return;
    free(f->u);
    free(f->v);
    free(f->u0);
    free(f->v0);
    free(f->d);
    free(f->d0);
    free(f);
}

void fluid_add_density(Fluid *f, int x, int y, float amount) {
    if (x < 1 || y < 1 || x > f->N || y > f->N) return;
    f->d0[fluid_ix(f, x, y)] += amount;
}

void fluid_add_velocity(Fluid *f, int x, int y, float fx, float fy) {
    if (x < 1 || y < 1 || x > f->N || y > f->N) return;
    size_t i = fluid_ix(f, x, y);
    f->u0[i] += fx;
    f->v0[i] += fy;
}

/* Enforce boundary conditions.
 *   b == 0 : scalar (density), copy neighbour value.
 *   b == 1 : horizontal velocity, mirror across vertical walls.
 *   b == 2 : vertical velocity, mirror across horizontal walls. */
static void set_bnd(int N, size_t stride, int b, float *x) {
    for (int i = 1; i <= N; i++) {
        x[IX(0, i)]     = (b == 1) ? -x[IX(1, i)] : x[IX(1, i)];
        x[IX(N + 1, i)] = (b == 1) ? -x[IX(N, i)] : x[IX(N, i)];
        x[IX(i, 0)]     = (b == 2) ? -x[IX(i, 1)] : x[IX(i, 1)];
        x[IX(i, N + 1)] = (b == 2) ? -x[IX(i, N)] : x[IX(i, N)];
    }
    x[IX(0, 0)]         = 0.5f * (x[IX(1, 0)] + x[IX(0, 1)]);
    x[IX(0, N + 1)]     = 0.5f * (x[IX(1, N + 1)] + x[IX(0, N)]);
    x[IX(N + 1, 0)]     = 0.5f * (x[IX(N, 0)] + x[IX(N + 1, 1)]);
    x[IX(N + 1, N + 1)] = 0.5f * (x[IX(N, N + 1)] + x[IX(N + 1, N)]);
}

/* Red-black Gauss-Seidel: same math as the classic in-place sweep but with a
 * checkerboard update order so each colour pass is embarrassingly parallel. */
static void lin_solve(int N, size_t stride, int b, float *x, const float *x0,
                      float a, float c) {
    const float invc = 1.0f / c;
    for (int k = 0; k < FLUID_GS_ITERS; k++) {
        for (int color = 0; color < 2; color++) {
#ifdef _OPENMP
#pragma omp parallel for schedule(static)
#endif
            for (int j = 1; j <= N; j++) {
                int start = 1 + ((j + color) & 1);
                for (int i = start; i <= N; i += 2) {
                    x[IX(i, j)] = (x0[IX(i, j)] +
                                   a * (x[IX(i - 1, j)] + x[IX(i + 1, j)] +
                                        x[IX(i, j - 1)] + x[IX(i, j + 1)])) *
                                  invc;
                }
            }
        }
        set_bnd(N, stride, b, x);
    }
}

static void diffuse(int N, size_t stride, int b, float *x, const float *x0,
                    float diff, float dt) {
    float a = dt * diff * (float)N * (float)N;
    lin_solve(N, stride, b, x, x0, a, 1.0f + 4.0f * a);
}

/* Semi-Lagrangian advection: trace each cell centre backwards through the
 * velocity field and bilinearly sample the previous field there. */
static void advect(int N, size_t stride, int b, float *d, const float *d0,
                   const float *u, const float *v, float dt) {
    float dt0 = dt * (float)N;
#ifdef _OPENMP
#pragma omp parallel for schedule(static)
#endif
    for (int j = 1; j <= N; j++) {
        for (int i = 1; i <= N; i++) {
            float x = (float)i - dt0 * u[IX(i, j)];
            float y = (float)j - dt0 * v[IX(i, j)];

            if (x < 0.5f) x = 0.5f;
            if (x > N + 0.5f) x = N + 0.5f;
            int i0 = (int)x, i1 = i0 + 1;

            if (y < 0.5f) y = 0.5f;
            if (y > N + 0.5f) y = N + 0.5f;
            int j0 = (int)y, j1 = j0 + 1;

            float s1 = x - i0, s0 = 1.0f - s1;
            float t1 = y - j0, t0 = 1.0f - t1;

            d[IX(i, j)] =
                s0 * (t0 * d0[IX(i0, j0)] + t1 * d0[IX(i0, j1)]) +
                s1 * (t0 * d0[IX(i1, j0)] + t1 * d0[IX(i1, j1)]);
        }
    }
    set_bnd(N, stride, b, d);
}

/* Hodge projection: subtract the gradient of pressure so velocity is
 * mass-conserving (divergence-free). */
static void project(int N, size_t stride, float *u, float *v, float *p,
                    float *div) {
    const float h = 1.0f / (float)N;
#ifdef _OPENMP
#pragma omp parallel for schedule(static)
#endif
    for (int j = 1; j <= N; j++) {
        for (int i = 1; i <= N; i++) {
            div[IX(i, j)] = -0.5f * h *
                            (u[IX(i + 1, j)] - u[IX(i - 1, j)] +
                             v[IX(i, j + 1)] - v[IX(i, j - 1)]);
            p[IX(i, j)] = 0.0f;
        }
    }
    set_bnd(N, stride, 0, div);
    set_bnd(N, stride, 0, p);

    lin_solve(N, stride, 0, p, div, 1.0f, 4.0f);

#ifdef _OPENMP
#pragma omp parallel for schedule(static)
#endif
    for (int j = 1; j <= N; j++) {
        for (int i = 1; i <= N; i++) {
            u[IX(i, j)] -= 0.5f * (p[IX(i + 1, j)] - p[IX(i - 1, j)]) / h;
            v[IX(i, j)] -= 0.5f * (p[IX(i, j + 1)] - p[IX(i, j - 1)]) / h;
        }
    }
    set_bnd(N, stride, 1, u);
    set_bnd(N, stride, 2, v);
}

void fluid_step(Fluid *f) {
    const int N = f->N;
    const size_t stride = f->stride;

    /* --- velocity step --- */
    /* sources already accumulated in u0/v0 via fluid_add_velocity */
    float *tmp;

    diffuse(N, stride, 1, f->u, f->u0, f->visc, f->dt);
    diffuse(N, stride, 2, f->v, f->v0, f->visc, f->dt);
    project(N, stride, f->u, f->v, f->u0, f->v0);

    /* swap so advection reads the projected field as "previous" */
    tmp = f->u0; f->u0 = f->u; f->u = tmp;
    tmp = f->v0; f->v0 = f->v; f->v = tmp;

    advect(N, stride, 1, f->u, f->u0, f->u0, f->v0, f->dt);
    advect(N, stride, 2, f->v, f->v0, f->u0, f->v0, f->dt);
    project(N, stride, f->u, f->v, f->u0, f->v0);

    /* --- density step --- */
    diffuse(N, stride, 0, f->d, f->d0, f->diff, f->dt);
    tmp = f->d0; f->d0 = f->d; f->d = tmp;
    advect(N, stride, 0, f->d, f->d0, f->u, f->v, f->dt);

    /* decay density + clear source buffers for next frame */
    const float decay = 0.995f;
#ifdef _OPENMP
#pragma omp parallel for schedule(static)
#endif
    for (size_t i = 0; i < f->cells; i++) {
        f->d[i] *= decay;
        f->d0[i] = 0.0f;
        f->u0[i] = 0.0f;
        f->v0[i] = 0.0f;
    }
}
