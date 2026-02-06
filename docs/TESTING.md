# Testing system

Lilush uses a minimal custom test framework called `testimony` (`src/testimony/`) for
regression prevention and refactoring safety. 

Tests live in `tests/` and organized into subdirs per module.

## Running Tests

### Testing after recent changes

After making changes, build lilush and run: 

* For running all tests (requires the binary to be in the repo root, which is default after build):
  ```bash
  ./run_all_tests.bash
  ```
* Or run individual test files:
  ```bash
  ./lilush tests/std/test_tbl.lua
  ```
