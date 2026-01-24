##### Build defaults #####
CC = clang
LUA_VERSION =       5.1
TARGET =            zx.so
PREFIX =            /usr/local
CFLAGS =            -O3 -Wall -pedantic -DNDEBUG -fPIC -fomit-frame-pointer
LUA_INCLUDE_DIR =   $(PREFIX)/include/luajit-2.1

BUILD_CFLAGS =      -I$(LUA_INCLUDE_DIR)
OBJS =              zx.o zx.audio.o

.PHONY: all clean

.c.o:
	$(CC) -c $(CFLAGS) $(CPPFLAGS) $(BUILD_CFLAGS) -o $@ $<

all: $(TARGET)

$(TARGET): $(OBJS)

clean:
	rm -f *.o $(TARGET)
