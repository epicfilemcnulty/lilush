# luasocket src/makefile
#

# MYCFLAGS: to be set by user if needed
MYCFLAGS?=

# MYLDFLAGS: to be set by user if needed
MYLDFLAGS?=

# DEBUG: NODEBUG DEBUG
# debug mode causes luasocket to collect and returns timing information useful
# for testing and debugging luasocket itself
DEBUG?=NODEBUG

#------
# Output file names
#
SO=so
O=o
SOCKET_V=0.9.0
MIME_V=1.0.3
SOCKET_SO=socket-$(SOCKET_V).$(SO)
MIME_SO=mime-$(MIME_V).$(SO)
UNIX_SO=unix.$(SO)
SERIAL_SO=serial.$(SO)
SOCKET=usocket.o

# Compiler and linker settings
# for Linux
CC=clang
LD=clang
DEF=-DLUASOCKET_$(DEBUG)
LUAINC?=/usr/local/include/luajit-2.1 /usr/local/include/wolfssl
CFLAGS=$(MYCFLAGS) $(LUAINC:%=-I%) $(DEF) -Wall -Wshadow -Wextra -Wimplicit -O2 -ggdb3 -fPIC
LDFLAGS=$(MYLDFLAGS) -O -fPIC -o

#------
# Modules belonging to socket-core
#
SOCKET_OBJS= \
	luasocket.$(O) \
	timeout.$(O) \
	buffer.$(O) \
	io.$(O) \
	auxiliar.$(O) \
	options.$(O) \
	inet.$(O) \
	$(SOCKET) \
	except.$(O) \
	select.$(O) \
	tcp.$(O) \
	udp.$(O)

#------
# Modules belonging mime-core
#
MIME_OBJS= \
	mime.$(O) 

#------
# Modules belonging unix (local domain sockets)
#
UNIX_OBJS=\
	buffer.$(O) \
	auxiliar.$(O) \
	options.$(O) \
	timeout.$(O) \
	io.$(O) \
	usocket.$(O) \
	unixstream.$(O) \
	unixdgram.$(O) \
	unix.$(O)

SSL_OBJS=\
	context.$(O) \
	ssl.$(O)
#------
# Modules belonging to serial (device streams)
#
SERIAL_OBJS=\
	buffer.$(O) \
	auxiliar.$(O) \
	options.$(O) \
	timeout.$(O) \
	io.$(O) \
	usocket.$(O) \
	serial.$(O)

#------
# Targets
#
all: $(SOCKET_SO) $(MIME_SO) $(UNIX_SO) $(SERIAL_SO)

$(SOCKET_SO): $(SOCKET_OBJS)

$(MIME_SO): $(MIME_OBJS)

$(UNIX_SO): $(UNIX_OBJS) $(SSL_OBJS)

$(SERIAL_SO): $(SERIAL_OBJS)

clean:
	rm -f $(SOCKET_SO) $(SOCKET_OBJS) $(SERIAL_OBJS)
	rm -f $(MIME_SO) $(UNIX_SO) $(SERIAL_SO) $(MIME_OBJS) $(UNIX_OBJS) $(SSL_OBJS)

.PHONY: all clean

#------
# List of dependencies
#
auxiliar.$(O): auxiliar.c auxiliar.h
buffer.$(O): buffer.c buffer.h io.h timeout.h
except.$(O): except.c except.h
inet.$(O): inet.c inet.h socket.h io.h timeout.h usocket.h
io.$(O): io.c io.h timeout.h
luasocket.$(O): luasocket.c luasocket.h auxiliar.h except.h \
	timeout.h buffer.h io.h inet.h socket.h usocket.h tcp.h \
	udp.h select.h
mime.$(O): mime.c mime.h
options.$(O): options.c auxiliar.h options.h socket.h io.h \
	timeout.h usocket.h inet.h
select.$(O): select.c socket.h io.h timeout.h usocket.h select.h
serial.$(O): serial.c auxiliar.h socket.h io.h timeout.h usocket.h \
  options.h unix.h buffer.h
tcp.$(O): tcp.c auxiliar.h socket.h io.h timeout.h usocket.h \
	inet.h options.h tcp.h buffer.h
timeout.$(O): timeout.c auxiliar.h timeout.h
udp.$(O): udp.c auxiliar.h socket.h io.h timeout.h usocket.h \
	inet.h options.h udp.h
unix.$(O): unix.c auxiliar.h socket.h io.h timeout.h usocket.h \
	options.h unix.h buffer.h
usocket.$(O): usocket.c socket.h io.h timeout.h usocket.h
context.$(O): context.c context.h common.h
ssl.$(O): ssl.c ssl.h context.h common.h socket.h io.h buffer.h timeout.h usocket.h
