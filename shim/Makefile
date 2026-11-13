CLANG ?= clang
SYSROOT ?= $(CURDIR)/../.build-sysroot
RESOURCE_INCLUDE := $(shell $(CLANG) -print-resource-dir)/include

CFLAGS ?= -O2 -g -fPIC -Wall -Wextra -fno-stack-protector -nostdinc \
          -isystem $(RESOURCE_INCLUDE) -isystem $(SYSROOT)/include

OBJ := link_shim.o
TARGET := libdsh-termux-native-link.so

DEVICE ?= masha_iqoo
DEVICE_DIR ?= /data/data/com.termux/files/home/.dsh-termux-native-build
SSHPASS_FILE ?= $(HOME)/.ssh/masha_iqoo_sshpass.txt

all: $(OBJ)

$(OBJ): link_shim.c
	$(CLANG) --target=aarch64-linux-gnu $(CFLAGS) -c -o $@ $<

# Fetch the device's own glibc headers so the object is compiled against the
# exact ABI the runtime uses.
fetch-sysroot:
	mkdir -p $(SYSROOT)
	sshpass -f $(SSHPASS_FILE) ssh $(DEVICE) \
	  'cd $$PREFIX/glibc && tar czf - include' | tar xzf - -C $(SYSROOT)

# Link on the device with its glibc binutils (no compiler is installed there).
device-link: $(OBJ)
	sshpass -f $(SSHPASS_FILE) ssh $(DEVICE) 'mkdir -p $(DEVICE_DIR)'
	sshpass -f $(SSHPASS_FILE) scp -q $(OBJ) $(DEVICE):$(DEVICE_DIR)/
	sshpass -f $(SSHPASS_FILE) ssh $(DEVICE) \
	  'cd $(DEVICE_DIR) && env -u LD_PRELOAD $$PREFIX/glibc/bin/ld \
	     -shared -soname $(TARGET) -o $(TARGET) $(OBJ) \
	     -L$$PREFIX/glibc/lib -lc -ldl'
	@echo "built $(DEVICE):$(DEVICE_DIR)/$(TARGET)"

link-hint: $(OBJ)
	@echo "scp $(OBJ) to the device, then:"
	@echo "  env -u LD_PRELOAD \$$PREFIX/glibc/bin/ld -shared -soname $(TARGET) \\"
	@echo "    -o $(TARGET) $(OBJ) -L\$$PREFIX/glibc/lib -lc -ldl"

clean:
	rm -f $(OBJ) $(TARGET)

.PHONY: all fetch-sysroot device-link link-hint clean