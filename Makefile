.PHONY: test lint format check

TEST_CMD = nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

check: test lint format

test:
	$(TEST_CMD)

lint:
	luacheck lua/ tests/

format:
	stylua lua/ tests/
