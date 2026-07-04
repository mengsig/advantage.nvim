#ifndef FLUID_H
#define FLUID_H

#include <stddef.h>

/* A "Stable Fluids" (Jos Stam, 2003) 2D solver on a square grid.
 *
 * The grid is (N+2)x(N+2): a 1-cell border is used for boundary conditions.
 * All fields are stored row-major in flat arrays of size (N+2)*(N+2). */

typedef struct {
    int    N;        /* interior grid resolution (NxN) */
    size_t stride;   /* N + 2 */
    size_t cells;    /* stride*stride */

    float  dt;       /* time step */
    float  diff;     /* diffusion rate for density */
    float  visc;     /* viscosity for velocity */

    /* Double-buffered fields. */
    float *u,  *v;   /* velocity, current */
    float *u0, *v0;  /* velocity, previous */
    float *d,  *d0;  /* density,  current / previous */
} Fluid;

Fluid *fluid_create(int N, float dt, float diff, float visc);
void   fluid_destroy(Fluid *f);

/* Add sources (deposited into the *_prev buffers before a step). */
void fluid_add_density(Fluid *f, int x, int y, float amount);
void fluid_add_velocity(Fluid *f, int x, int y, float fx, float fy);

/* Advance the simulation by one time step. */
void fluid_step(Fluid *f);

/* Index helper: cell (x,y) with 0<=x,y<=N+1. */
static inline size_t fluid_ix(const Fluid *f, int x, int y) {
    return (size_t)x + f->stride * (size_t)y;
}

#endif /* FLUID_H */
