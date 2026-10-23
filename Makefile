.PHONY: build test conformance shim-upgrade crash-test slice-test immutable-test opcode-test wire-test
# Shell-script suites tests/run-<name>-test.sh not listed individually below.
# readtier-test is excluded (its build writes lib_coreir, read-only in the sandbox); readtier-durable runs the test alone.
# ids/wire need gitignored binaries: run `make test-prereqs` first (not folded in here).
EXTRA_TESTS = readtier-durable admit-validate count firstcontact ids mask maxrecord ownership stale store-files store-util concurrent
EXTRA_TARGETS = $(addsuffix -test,$(addprefix run-,$(EXTRA_TESTS)))

test: conformance crash-test slice-test immutable-test opcode-test wire-test $(EXTRA_TARGETS)

.PHONY: $(EXTRA_TARGETS)
$(EXTRA_TARGETS): run-%-test:
	bash tests/run-$*-test.sh
conformance: shim-upgrade

shim-upgrade:
	bash shim/tests/run-shim-upgrade.sh

# REQ-10: per-stream dense block ids, none reissued across SIGKILL restarts
crash-test:
	bash tests/run-crash-test.sh

slice-test:
	bash tests/run-slice-test.sh

# REQ-11: append-only; identical re-admit adds a record, QUERY stays a set; old block bytes unchanged
immutable-test:
	bash tests/run-immutable-test.sh

# REQ-12: closed op set (1,2,3); every other opcode -> UNKNOWN opcode N
opcode-test:
	bash tests/run-opcode-test.sh

shim-build:
	bash shim/build-shim.sh

wire-test:
	bash tests/run-wire-test.sh

build:
	bash scripts/build.sh

.PHONY: readtier-test
readtier-test:
	bash scripts/build-readtier.sh && bash tests/run-readtier-durable-test.sh

.PHONY: test-prereqs
# Build the gitignored binaries run-ids-test.sh / run-wire-test.sh need.
test-prereqs:
	$(MAKE) build
	bash scripts/build-readtier.sh
	$(MAKE) shim-build

# Run seal outside the sandbox (cargo needs network/toolchain dirs).
seal:
	bash tests/seal.sh

