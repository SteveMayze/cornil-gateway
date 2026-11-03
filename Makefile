# cornil-gateway. Run `make help` to list targets.
# Routine targets use SSH as the service user and NO sudo. Only the three targets marked [SUDO] ask for
# the sudo password, and each one says what it changes in its playbook header.
VENV      := .venv-infra
ANSIBLE   := ANSIBLE_CONFIG=ansible/ansible.cfg $(VENV)/bin/ansible-playbook -i local/inventory.ini $(if $(wildcard local/vars.yml),-e @local/vars.yml) $(if $(HTTP_PORT),-e gateway_http_port=$(HTTP_PORT)) $(if $(HTTPS_PORT),-e gateway_https_port=$(HTTPS_PORT))

.PHONY: pg-backup-deploy pg-backup-now pg-restore-drill pg-restore restic-deploy restic-secret disk-status bootstrap-disk-health pg-deploy pg-deploy-check pg-status pg-create-app restore-drill restore-caddy-data quadlet-dryrun deploy-check help hooks ansible-setup syntax check test secrets-scan render deploy status backup-caddy-data root-cert smoke bootstrap-ports cutover rollback-legacy

help:  ## Show this list
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

hooks:  ## Turn on the pre-commit secret scan for this clone
	git config core.hooksPath scripts/hooks

ansible-setup:  ## Once on your Mac: install Ansible into a private folder (.venv-infra)
	python3 -m venv $(VENV) && $(VENV)/bin/pip install --quiet ansible-core

secrets-scan:  ## Scan the whole git history and working tree for secrets
	gitleaks git --redact --verbose .
	gitleaks dir --redact --verbose .

syntax:  ## Check that every playbook is well-formed; changes nothing
	for p in deploy backup-caddy-data status root-cert restore-caddy-data bootstrap-ports cutover rollback-legacy render postgres-deploy postgres-status pg-create-app pg-backup-deploy pg-backup-now pg-restore-drill pg-restore restic-deploy bootstrap-disk-health disk-status; do \
	  ANSIBLE_CONFIG=ansible/ansible.cfg $(VENV)/bin/ansible-playbook -i local/inventory.example.ini --syntax-check ansible/$$p.yml || exit 1; done

test:  ## Run the tests on the real rendered files (needs a local caddy: brew install caddy)
	scripts/test.sh

check: secrets-scan test  ## All checks: secret scan + tests

render:  ## Write the rendered Caddyfile and unit files to ./build for inspection
	ANSIBLE_CONFIG=ansible/ansible.cfg $(VENV)/bin/ansible-playbook -i localhost, ansible/render.yml -e @ansible/group_vars/all.yml

deploy:  ## Deploy or update Caddy on the server (no sudo). Trial ports: make deploy HTTP_PORT=8080 HTTPS_PORT=8443
	$(ANSIBLE) ansible/deploy.yml

deploy-check:  ## Rehearse a deploy without changing anything (ansible --check --diff)
	$(ANSIBLE) ansible/deploy.yml --check --diff

status:  ## Read-only overview of the gateway on the server
	$(ANSIBLE) ansible/status.yml

backup-caddy-data:  ## Back up Caddy's data dir (the CA, private key included) on the server
	$(ANSIBLE) ansible/backup-caddy-data.yml

root-cert:  ## Fetch Caddy's PUBLIC root certificate to local/cornil-root.crt
	$(ANSIBLE) ansible/root-cert.yml
	scripts/root-cert.sh local/cornil-root.crt

smoke:  ## Check the gateway end to end. Trial ports: make smoke HTTPS_PORT=8443 HTTP_PORT=8080
	HTTPS_PORT=$(or $(HTTPS_PORT),443) HTTP_PORT=$(or $(HTTP_PORT),80) scripts/smoke.sh

bootstrap-ports:  ## [SUDO, once] Allow ordinary users to listen on port 80 and up
	$(ANSIBLE) -K -l admin ansible/bootstrap-ports.yml

cutover:  ## [SUDO] Back up and stop the legacy Caddy so the new one can take ports 80/443
	$(ANSIBLE) -K -l admin ansible/cutover.yml

rollback-legacy:  ## [SUDO] Put the legacy Caddy back and stop the new one
	$(ANSIBLE) -K ansible/rollback-legacy.yml

pg-backup-deploy:  ## Install the nightly PostgreSQL dump (scripts, service, timer; no sudo)
	$(ANSIBLE) ansible/pg-backup-deploy.yml

pg-backup-now:  ## Take a PostgreSQL dump right now and list the dumps
	$(ANSIBLE) ansible/pg-backup-now.yml

pg-restore-drill:  ## Prove the newest dump restores (into a throw-away database; live data untouched). Optional: DB=partsdb DUMP=...
	$(ANSIBLE) ansible/pg-restore-drill.yml $(if $(DB),-e db=$(DB)) $(if $(DUMP),-e dump=$(DUMP))

pg-restore:  ## Replace a live database from a dump (asks you to type RESTORE; the old one is kept aside). make pg-restore DB=... DUMP=...
	@test -n "$(DB)" -a -n "$(DUMP)" || { echo "Give DB=<database> DUMP=<dump file name>; list them with: make pg-status"; exit 1; }
	@printf 'This replaces the live database %s with %s (the old one is kept aside). Is the app using it stopped? Type RESTORE to continue: ' "$(DB)" "$(DUMP)"; read a; test "$$a" = RESTORE
	$(ANSIBLE) ansible/pg-restore.yml -e db=$(DB) -e dump=$(DUMP) -e confirm=RESTORE

restic-secret:  ## Create one Podman secret on the server from a hidden prompt there. make restic-secret NAME=restic-repo-password
	@test -n "$(NAME)" || { echo "Give NAME=<secret name>, for example NAME=restic-repo-password"; exit 1; }
	scripts/restic-secret.sh $(NAME)

restic-deploy:  ## Install the offsite backup service and timer (restic as a container; no credentials; not enabled until U4)
	$(ANSIBLE) ansible/restic-deploy.yml

disk-status:  ## Show the disk health status file (SMART summary, USB resets, I/O errors; no sudo)
	$(ANSIBLE) ansible/disk-status.yml

bootstrap-disk-health:  ## [SUDO, once] Install smartmontools and the root job that writes the disk health status file
	$(ANSIBLE) -K -l admin ansible/bootstrap-disk-health.yml

pg-deploy:  ## Install or update the shared PostgreSQL on the server (no sudo; creates an empty server)
	$(ANSIBLE) ansible/postgres-deploy.yml

pg-deploy-check:  ## Rehearse pg-deploy without changing anything (ansible --check --diff)
	$(ANSIBLE) ansible/postgres-deploy.yml --check --diff

pg-status:  ## Read-only overview of PostgreSQL: health, databases, roles, secret names (no values)
	$(ANSIBLE) ansible/postgres-status.yml

pg-create-app:  ## Add an app's database, role and password secret (idempotent). make pg-create-app APP=partsdb
	@test -n "$(APP)" || { echo "Give APP=<name>, for example: make pg-create-app APP=partsdb"; exit 1; }
	$(ANSIBLE) ansible/pg-create-app.yml -e app=$(APP)

quadlet-dryrun:  ## Ask the server's Quadlet generator to translate our unit files (prints only)
	scripts/quadlet-dryrun.sh

restore-drill:  ## Prove a backup is usable: unpack it into a throw-away folder and compare certificates. make restore-drill BACKUP=caddy-data-....tar.gz
	@test -n "$(BACKUP)" || { echo "Give BACKUP=<name>; list them with: ssh <service user>@<server> ls ~/cornil-gateway/backups"; exit 1; }
	$(ANSIBLE) ansible/restore-caddy-data.yml -e drill=true -e backup=$(BACKUP)

restore-caddy-data:  ## Replace the live CA data with a backup (asks you to type RESTORE). make restore-caddy-data BACKUP=...
	@test -n "$(BACKUP)" || { echo "Give BACKUP=<name>"; exit 1; }
	@printf 'This replaces the live Caddy CA data with %s. Type RESTORE to continue: ' "$(BACKUP)"; read a; test "$$a" = RESTORE
	$(ANSIBLE) ansible/restore-caddy-data.yml -e drill=false -e confirm=RESTORE -e backup=$(BACKUP)
