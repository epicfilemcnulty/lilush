### LuaSocketWolfSSL

[LuaSocket](https://github.com/lunarmodules/luasocket) version `3.1.0` was taken as a
base. 

* Support for all other platforms but Linux was ruthlessly stripped away. 
* SSL support was integrated.

It is based on [Luasec](https://github.com/brunoos/luasec) library version `1.2.0`, which was modified to
work with [WolfSSL](https://www.wolfssl.com/) instead of OpenSSL.
