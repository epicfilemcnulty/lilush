##### Build defaults #####
CC = clang
TARGET =            crypto.so
PREFIX =            /usr/local
CFLAGS =            -O3 -Wall -pedantic -DNDEBUG -fPIC
LUA_INCLUDE_DIR =   $(PREFIX)/include/luajit-2.1 

BUILD_CFLAGS =      -I$(LUA_INCLUDE_DIR) -I/usr/local/include/wolfssl
OBJS =              crypto.o

.PHONY: all clean

.c.o:
	$(CC) -c $(CFLAGS) $(CPPFLAGS) $(BUILD_CFLAGS) -o $@ $<

all: $(TARGET)

$(TARGET): $(OBJS)

clean:
	rm -f *.o $(TARGET)
