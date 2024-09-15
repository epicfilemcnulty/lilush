## Implement postgreSQL lib


## Kitty graphics protocol support

    Start with plain ol' PNGs

## Add basic `curl` functionality

    Either add it to `kat` or introduce `kurl`. Probably `kurl`.

## Packaging

    Need digital signatures for that,
    so have to expose a bit more of WolfCrypt API...

## Vault API lib

    Good to have, at least something simple to directly read secrets from Vault's KV,
    then we could have an internal vault agent and do something like:

    ```
    setenv MY_API_TOKEN vault://secret/api/my_token
    ```

## Synchronized output support:

  * https://gist.github.com/christianparpart/d8a62cc1ab659194337d73e399004036
  * https://github.com/kovidgoyal/kitty/commit/5768c54c5b5763e4bbb300726b8ff71b40c128f8

  Looks like a useful feature to have.

  Terminfo rant: https://twoot.site/@bean/113056942625234032

## AWS lib integration

   Gotta find the time to revisit AWS lib drafts...

## OIDC Client
