CC = clang
##### Build defaults #####
LUA_VERSION =       5.1
TARGET =            cjson.so
PREFIX =            /usr/local
CFLAGS =            -O3 -Wall -pedantic -DNDEBUG
CJSON_CFLAGS =      -fpic
LUA_INCLUDE_DIR =   $(PREFIX)/include/luajit-2.1

##### Number conversion configuration #####

## Use built in number conversion
FPCONV_OBJS =       g_fmt.o dtoa.o
CJSON_CFLAGS +=     -DUSE_INTERNAL_FPCONV
BUILD_CFLAGS =      -I$(LUA_INCLUDE_DIR) $(CJSON_CFLAGS)
OBJS =              lua_cjson.o strbuf.o $(FPCONV_OBJS)

.PHONY: all clean

.c.o:
	$(CC) -c $(CFLAGS) $(CPPFLAGS) $(BUILD_CFLAGS) -o $@ $<

all: $(TARGET)

$(TARGET): $(OBJS)

clean:
	rm -f *.o $(TARGET)
