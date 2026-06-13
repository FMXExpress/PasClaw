# Local Docker build + smoke for the DigitalOcean App Platform image.
# All targets run from the REPO ROOT (not from inside digitalocean/) so
# the build context picks up src/, Makefile, etc.
#
# Examples:
#   make -C digitalocean build
#   make -C digitalocean run
#   make -C digitalocean health
#
# Or from the repo root:
#   make -f digitalocean/Makefile build

IMAGE      ?= pasclaw-do:local
PORT       ?= 8088
ENV_FILE   ?= digitalocean/.env.example
DATA_VOL   ?= pasclaw-do-data

# Path to the repo root from this Makefile's location.
REPO_ROOT  := $(abspath $(dir $(firstword $(MAKEFILE_LIST)))/..)

.PHONY: build run logs stop health clean

build:
	cd $(REPO_ROOT) && docker build \
	  -t $(IMAGE) \
	  -f Dockerfile \
	  .

# Run the image locally with a named volume mimicking the App Platform
# persistent disk. --env-file loads .env.example -- copy it to .env and
# edit before running so secrets aren't sourced from the placeholder file.
run:
	@if [ ! -f $(REPO_ROOT)/digitalocean/.env ]; then \
	  echo "warning: digitalocean/.env not found; copy .env.example and edit it"; \
	  echo "         using .env.example for now -- expect placeholder API errors"; \
	fi
	docker run --rm -it \
	  --name pasclaw-do \
	  -p $(PORT):8088 \
	  --env-file $(if $(wildcard $(REPO_ROOT)/digitalocean/.env),$(REPO_ROOT)/digitalocean/.env,$(REPO_ROOT)/$(ENV_FILE)) \
	  -v $(DATA_VOL):/data/pasclaw \
	  $(IMAGE)

# Tail logs of a detached run.
logs:
	docker logs -f pasclaw-do

stop:
	-docker stop pasclaw-do
	-docker rm pasclaw-do

# Hit /v1/health -- exempt from gateway-token auth so no bearer needed.
health:
	curl -fsS http://localhost:$(PORT)/v1/health && echo

# Smoke test that authenticated routes refuse without a token, then accept
# with the right one. Requires `jq` and a running container.
smoke:
	@echo "1. /v1/health (no auth) ..."
	@curl -fsS http://localhost:$(PORT)/v1/health > /dev/null && echo "   OK"
	@echo "2. /v1/status without bearer ..."
	@status=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$(PORT)/v1/status); \
	  if [ "$$status" = "401" ]; then echo "   OK (401 as expected)"; \
	  else echo "   FAIL: expected 401, got $$status"; exit 1; fi
	@echo "3. /v1/status with bearer (set TOKEN env to your gateway token) ..."
	@if [ -z "$(TOKEN)" ]; then echo "   skipped: set TOKEN=... to run"; exit 0; fi
	@curl -fsS -H "Authorization: Bearer $(TOKEN)" http://localhost:$(PORT)/v1/status > /dev/null && echo "   OK"

# Wipe the data volume -- destroys local sessions / memory / KB.
clean:
	-docker volume rm $(DATA_VOL)
