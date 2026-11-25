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

# Link on the device. There is no aarch64 ELF linker on the development host,
# so the object is shipped over and linked by Termux's own linker:
#   - Termux's binutils package installs `ld.bfd` (there is no bare `ld`);
#   - $PREFIX/glibc/bin/ld only exists while glibc-runner is installed.
# No compiler is needed on the device, just a linker. Debug info is stripped
# afterwards so the artifact matches the one committed under dist/.
device-link: $(OBJ)
	sshpass -f $(SSHPASS_FILE) ssh $(DEVICE) 'mkdir -p $(DEVICE_DIR)'
	sshpass -f $(SSHPASS_FILE) scp -q $(OBJ) $(DEVICE):$(DEVICE_DIR)/
	sshpass -f $(SSHPASS_FILE) ssh $(DEVICE) \
	  'cd $(DEVICE_DIR) && \
	   for c in "$${LD:-}" "$$(command -v ld || true)" "$$PREFIX/bin/ld.bfd" "$$PREFIX/glibc/bin/ld"; do \
	     if [ -n "$$c" ] && [ -x "$$c" ]; then LD_LINKER="$$c"; break; fi; \
	   done; \
	   [ -n "$${LD_LINKER:-}" ] || { echo "!! no ld on $(DEVICE): pkg install -y binutils" >&2; exit 1; }; \
	   echo "== ld: $$LD_LINKER"; \
	   env -u LD_PRELOAD "$$LD_LINKER" -shared -soname $(TARGET) -o $(TARGET) $(OBJ) \
	     -L$$PREFIX/glibc/lib -lc -ldl || exit $$?; \
	   STRIP="$$(command -v gstrip || true)"; \
	   if [ -n "$$STRIP" ]; then \
	     echo "== strip: $$STRIP"; env -u LD_PRELOAD "$$STRIP" --strip-debug $(TARGET); \
	   fi'
	@echo "built $(DEVICE):$(DEVICE_DIR)/$(TARGET)"

link-hint: $(OBJ)
	@echo "scp $(OBJ) to the device, then run there:"
	@echo "  cd $(DEVICE_DIR)"
	@echo "  LD_LINKER=\$${LD:-\$$PREFIX/bin/ld.bfd}   # pkg install -y binutils; or \$$PREFIX/glibc/bin/ld"
	@echo "  env -u LD_PRELOAD \"\$$LD_LINKER\" -shared -soname $(TARGET) -o $(TARGET) $(OBJ) \\"
	@echo "    -L\$$PREFIX/glibc/lib -lc -ldl"

clean:
	rm -f $(OBJ) $(TARGET)

.PHONY: all fetch-sysroot device-link link-hint clean