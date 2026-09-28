# fpemu: library + bare-metal differential test on QEMU.
#   make test   builds, runs the suite on a real-FPU CPU and on an FPU-less
#               CPU (every F/D instruction emulated), and diffs the outputs.
CROSS  ?= riscv64-unknown-elf-
CC      = $(CROSS)gcc
OBJDUMP = $(CROSS)objdump
QEMU   ?= qemu-system-riscv32
ARCH    = -march=rv32imafdc_zicsr_zifencei -mabi=ilp32d
SF_INC  = -Isoftfloat-platform -Isoftfloat/source/RISCV -Isoftfloat/source/include
CFLAGS  = $(ARCH) -O2 -g -ffreestanding -fno-builtin -mcmodel=medany -Wall -Wextra -Iinclude $(SF_INC)
SF_FLAGS = $(ARCH) -O2 -ffreestanding -mcmodel=medany -DSOFTFLOAT_FAST_INT64 $(SF_INC) -Wno-unused-parameter

SF_SRC  = $(addprefix softfloat/,$(shell cat softfloat-sources.txt))
SF_OBJ  = $(patsubst softfloat/source/%.c,build/sf/%.o,$(SF_SRC))

all: build/libfpemu.a build/tests.elf check-no-fp

build/sf/%.o: softfloat/source/%.c
	@mkdir -p $(dir $@)
	$(CC) $(SF_FLAGS) -c $< -o $@

build/fpemu.o: src/fpemu.c include/fpemu.h
	@mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

build/libfpemu.a: build/fpemu.o $(SF_OBJ)
	rm -f $@
	$(CROSS)ar rcs $@ $^

build/tests.elf: test/start.S test/harness.c test/tests.c build/libfpemu.a test/link.ld
	$(CC) $(CFLAGS) $(EXTRA) -nostdlib -T test/link.ld test/start.S test/harness.c \
	  test/tests.c build/libfpemu.a -lgcc -o $@

# The emulator runs with the FPU off inside the trap: it must contain no F/D
# instruction itself.
check-no-fp: build/libfpemu.a
	@n=$$($(OBJDUMP) -d build/libfpemu.a | awk -F'\t' '$$3 ~ /^(c\.)?f/ && $$3 !~ /^fence/' | wc -l); \
	if [ $$n -ne 0 ]; then echo "ERROR: $$n F/D instructions in libfpemu.a"; exit 1; \
	else echo "check-no-fp: libfpemu.a has no F/D instructions"; fi

QEMU_ARGS = -machine virt -bios none -nographic -m 128M -kernel build/tests.elf
NOFPU     = rv32,f=false,d=false,zfa=false,zfh=false,zfhmin=false

test: all
	$(QEMU) $(QEMU_ARGS) -cpu rv32 > build/hw.txt
	$(QEMU) $(QEMU_ARGS) -cpu $(NOFPU) > build/emu.txt
	@grep -v '^emulated=' build/hw.txt > build/hw.cmp
	@grep -v '^emulated=' build/emu.txt > build/emu.cmp
	@grep -q '^DONE' build/emu.cmp && grep -q '^DONE' build/hw.cmp
	@grep '^emulated=' build/emu.txt
	@diff build/hw.cmp build/emu.cmp && echo "PASS: $$(grep -c ' h=' build/hw.cmp) groups identical"

clean:
	rm -rf build
.PHONY: all test check-no-fp clean
