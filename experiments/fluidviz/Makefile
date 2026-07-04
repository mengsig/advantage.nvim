# fluidviz — real-time stable-fluids terminal visualiser
CC      ?= cc
CFLAGS  ?= -O3 -march=native -ffast-math -funroll-loops -Wall -Wextra -std=c11
LDFLAGS ?=
LDLIBS  ?= -lm

# OpenMP is optional; enable with `make OPENMP=1`.
ifeq ($(OPENMP),1)
CFLAGS  += -fopenmp
LDFLAGS += -fopenmp
endif

BIN  = fluidviz
SRC  = main.c fluid.c
OBJ  = $(SRC:.c=.o)
DEPS = fluid.h

all: $(BIN)

$(BIN): $(OBJ)
	$(CC) $(LDFLAGS) -o $@ $(OBJ) $(LDLIBS)

%.o: %.c $(DEPS)
	$(CC) $(CFLAGS) -c -o $@ $<

run: $(BIN)
	./$(BIN)

bench: $(BIN)
	./$(BIN) --bench 300 --n 192

clean:
	rm -f $(BIN) $(OBJ)

.PHONY: all run bench clean
