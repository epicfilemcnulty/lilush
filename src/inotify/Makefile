##### Build defaults #####
CC = clang
LUA_VERSION =       5.1
TARGET =            inotify.so
CFLAGS =            -O3 -Wall -pedantic -DNDEBUG -fPIC
LUA_INCLUDE_DIR =   /usr/local/include/luajit-2.1

BUILD_CFLAGS =      -I$(LUA_INCLUDE_DIR)
OBJS =              inotify.o

.PHONY: all clean

.c.o:
	$(CC) -c $(CFLAGS) $(CPPFLAGS) $(BUILD_CFLAGS) -o $@ $<

all: $(TARGET)

$(TARGET): $(OBJS)

clean:
	rm -f *.o $(TARGET)
