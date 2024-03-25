##### Build defaults #####
CC = clang
LUA_VERSION =       5.1
TARGET =            term.so
PREFIX =            /usr/local
CFLAGS =            -O3 -Wall -pedantic -DNDEBUG -fPIC
LUA_INCLUDE_DIR =   $(PREFIX)/include/luajit-2.1

BUILD_CFLAGS =      -I$(LUA_INCLUDE_DIR)
OBJS =              term.o

.PHONY: all clean

.c.o:
	$(CC) -c $(CFLAGS) $(CPPFLAGS) $(BUILD_CFLAGS) -o $@ $<

all: $(TARGET)

$(TARGET): $(OBJS)

clean:
	rm -f *.o $(TARGET)
