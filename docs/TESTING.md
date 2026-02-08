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

### Focused LLM/Agent refactor checks

When changing `src/llm` or `src/agent`, run:

```bash
./lilush tests/llm/test_tools_loop.lua
./lilush tests/llm/test_clients_phase1.lua
./lilush tests/llm/test_clients_phase3.lua
./lilush tests/llm/test_builtin_tools_phase2.lua
./lilush tests/llm/test_templates_pricing.lua
./lilush tests/agent/test_config.lua
./lilush tests/agent/test_conversation.lua
./lilush tests/agent/test_stream.lua
./lilush tests/shell/test_mode_agent.lua
```
