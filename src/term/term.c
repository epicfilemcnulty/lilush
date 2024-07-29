// SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: GPL-3.0-or-later
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include <lauxlib.h>
#include <lua.h>

#define RETURN_ERR(L)                                                          \
  do {                                                                         \
    lua_pushnil(L);                                                            \
    lua_pushstring(L, strerror(errno));                                        \
    return 2;                                                                  \
  } while (0)
#define RETURN_CUSTOM_ERR(L, msg)                                              \
  do {                                                                         \
    lua_pushnil(L);                                                            \
    lua_pushstring(L, msg);                                                    \
    return 2;                                                                  \
  } while (0)

int window_been_resized = 0;
int window_x = 0;
int window_y = 0;
int in_raw_mode = 2;

static void sig_handler(int sig) {
  if (SIGWINCH == sig) {
    window_been_resized = 1;
    int ret = -1;
    struct winsize winsz;
    ret = ioctl(STDIN_FILENO, TIOCGWINSZ, &winsz);
    if (ret == 0) {
      window_y = winsz.ws_row;
      window_x = winsz.ws_col;
    }
  }
}

int set_raw_mode(lua_State *L) {
  if (in_raw_mode == 1) {
    lua_pushboolean(L, 1);
    return 1;
  }
  if (!isatty(STDIN_FILENO)) {
    RETURN_CUSTOM_ERR(L, "not attached to tty");
  }
  struct termios tty_state;
  if (tcgetattr(STDIN_FILENO, &tty_state) == -1) {
    RETURN_ERR(L);
  }

  /* read() timeout is in tenths of a second,
     we set it to 100 milliseconds by
     default if no timeout provided */
  int read_timeout = luaL_optint(L, 1, 1);

  tty_state.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
  tty_state.c_oflag &= ~(OPOST);
  tty_state.c_cflag |= (CS8);
  tty_state.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
  tty_state.c_cc[VMIN] = 0;
  tty_state.c_cc[VTIME] = read_timeout;
  if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &tty_state) == -1) {
    RETURN_ERR(L);
  }
  in_raw_mode = 1;
  lua_pushboolean(L, 1);
  return 1;
}

int set_sane_mode(lua_State *L) {

  if (in_raw_mode == 0) {
    lua_pushboolean(L, 1);
    return 1;
  }

  if (!isatty(STDIN_FILENO)) {
    RETURN_CUSTOM_ERR(L, "not attached to tty");
  }

  struct termios sane;

  // Get current terminal attributes
  if (tcgetattr(STDIN_FILENO, &sane) == -1) {
    RETURN_ERR(L);
  }

  // Set 'sane' terminal attributes
  sane.c_iflag = ICRNL | BRKINT | IMAXBEL;
  sane.c_oflag = OPOST | ONLCR;
  sane.c_lflag =
      ISIG | ICANON | IEXTEN | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE;
  sane.c_cflag = CREAD | CS8 | HUPCL;
  sane.c_cc[VMIN] = 1;
  sane.c_cc[VTIME] = 0;

  // Set the terminal attributes
  if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &sane) == -1) {
    RETURN_ERR(L);
  }

  in_raw_mode = 0;
  lua_pushboolean(L, 1);
  return 1;
}

int get_window_size(lua_State *L) {
  lua_pushinteger(L, window_y);
  lua_pushinteger(L, window_x);
  return 2;
}

int resized(lua_State *L) {
  lua_pushboolean(L, window_been_resized);
  if (window_been_resized) {
    window_been_resized = 0;
  }
  return 1;
}

static luaL_Reg funcs[] = {{"set_raw_mode", set_raw_mode},
                           {"set_sane_mode", set_sane_mode},
                           {"get_window_size", get_window_size},
                           {"resized", resized},
                           {NULL, NULL}};

int luaopen_term_core(lua_State *L) {

  // Capture SIGWINCH
  sig_handler(SIGWINCH);
  signal(SIGWINCH, sig_handler);
  window_been_resized = 0;
  /* Return the module */
  luaL_newlib(L, funcs);
  return 1;
}
