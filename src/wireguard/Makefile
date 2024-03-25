##### Build defaults #####
CC = clang
LUA_VERSION =       5.1
TARGET =            wireguard.so
PREFIX =            /usr/local
CFLAGS =            -O3 -Wall -pedantic -DNDEBUG -fPIC
LUA_INCLUDE_DIR =   $(PREFIX)/include/luajit-2.1

BUILD_CFLAGS =      -I$(LUA_INCLUDE_DIR) -I/usr/include/libnl3
OBJS =              wireguard.o lua_wireguard.o

.PHONY: all clean

.c.o:
	$(CC) -c $(CFLAGS) $(CPPFLAGS) $(BUILD_CFLAGS) -o $@ $<

all: $(TARGET)

$(TARGET): $(OBJS)

clean:
	rm -f *.o $(TARGET)
