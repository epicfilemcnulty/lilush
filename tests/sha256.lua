#!/bin/lilush

local crypto = require("crypto")

print("Test SHA256...")
assert(crypto.bin_to_hex(crypto.sha256("")) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
assert(
	crypto.bin_to_hex(crypto.sha256("Omnia Galia divisa in partes tres"))
		== "f17c6976956b98e99fccd4152d7ed1289a3c5c18b4ed92fb5c8fb9dded2fb29e",
	"failed!"
)
print("OK.")
print("Test HMAC-SHA256")
assert(
	crypto.bin_to_hex(crypto.hmac("key", "The quick brown fox jumps over the lazy dog"))
		== "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
	"failed!"
)
print("OK.")
