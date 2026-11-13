# Offsite backup target: Synology NAS over SFTP with a key (setup checklist)

Status: **executed 2026-11-09 (sections A to F, G1, G2, G4); G3 restore proof and G5 records done 2026-11-13.** Written for Phase U4 (ADR 0007). Companion to `docs/offsite-backup.md` (option A, "a NAS you own"). The corrections found during the run are worked into the steps and listed under "What the real run showed".

Target: Synology DS218, DSM 7.2.2-72806 Update 8, network name `barnes.fritz.box`. Source: the home server `cornil.fritz.box`. Goal: `restic` (a container on cornil) logs in to the NAS **with a key, no password**, as a normal (non-admin) NAS user and writes only into one shared folder.

## Machine legend
- **[MacBook]**: your Mac. Used for the DSM web page (`https://barnes.fritz.box:5001`) and for `make` in this repo.
- **[Cornil]**: a terminal on `cornil.fritz.box` as the service user (`ssh <service-user>@cornil.fritz.box`). The key lives here and never leaves.
- **[Barnes]**: the NAS. Mostly done in the DSM web page from the MacBook. Some steps are done *through* an SFTP session opened from Cornil.

## Variables (CLAUDE.md rule 6: real user names are not stored in git)
Paste this block at the top of every new terminal on [Cornil] and fill in your own values. They are the names you already created on the NAS.

    NAS=barnes.fritz.box
    NAS_USER=<the NAS user you created>      # a normal DSM user, NOT in the administrators group
    NAS_SHARE=<the shared folder you created>
    KEYDIR="$HOME/cornil-platform/restic-ssh"

## What is going on (why the first attempt failed)
Three facts explain "password works, key does not, ssh refused":

1. **The key is only read from the user's home folder, and only if the permissions are strict.** On DSM the home folder is `/volume1/homes/<user>` (shown as `/home` inside SFTP; the same folder is `homes/<user>` in File Station). The file must be `~/.ssh/authorized_keys`, owned by that user. OpenSSH silently ignores it when the home folder is group- or world-writable, and DSM's default for new home folders is wide open (777 according to the guides). Forum evidence: the DSM 7 thread on synoforum shows the server log line `Ignored authorized keys: bad ownership or modes for directory /volume1/homes/<user>`. This was the most likely cause before the real run; on 2026-11-09 the actual blocker turned out to be an ACL on the key file (C1b), not the modes. `ssh-copy-id` cannot be used because a non-admin DSM user has no password login shell.
2. **Only members of the administrators group can open an ssh *shell* on DSM.** A normal user can still use SFTP (that is all restic needs: it asks the server for the "sftp" subsystem). So "connection refused / permission denied" on plain `ssh` is expected for the backup user and is not a problem. A refusal of the *connection* itself (nothing listening) usually means the service is off or on another port; section B1 checks that.
3. **SFTP paths on DSM start at a virtual root, not at `/home/...`.** You see `/home` (your own home folder) and `/<share name>`. restic needs an absolute repository path that starts with `/` on Synology (restic FAQ), so the repository will be `/<share>/restic`.

## Checklist (in this order)

### A. [Barnes, DSM web page from the MacBook] Prepare the NAS
Menu names are from DSM 7.2 as I know it; I could not load Synology's DSM help pages in this session, so check the label if one looks different.
- [ ] A1. **Control Panel > File Services > FTP tab**: under *SFTP*, tick **Enable SFTP service**, port **22** (default). Leave FTP and FTPS off. Apply. Note the port if you change it.
- [ ] A2. **Control Panel > User & Group > Advanced**: confirm **Enable user home service** is ticked. (It effectively is, because `/homes/<user>` exists. Nothing to do if ticked.)
- [ ] A3. **Control Panel > Shared Folder > Edit (your share) > General**: untick **Enable Recycle Bin** (restic prunes lots of files; the bin would keep them and fill the disk). Do not encrypt the share (restic already encrypts). Optional: a quota on the share.
- [ ] A4. **Control Panel > User & Group > Edit (your backup user)**:
  - *Groups*: only `users` (not `administrators`).
  - *Permissions*: **Read/Write** on your share; **No access** on every other share. (The `homes` share is handled by DSM.)
  - *Applications*: **allow SFTP** (on some DSM 7 builds the row is called FTP and covers SFTP), **deny** DSM, File Station, SMB and everything else.
- [ ] A5. **Control Panel > Security > Firewall**: a profile with **no rules lets everything through**, so nothing to do (this was the case here). Only if you have a final "Deny" rule, add an allow rule for port 22 from the LAN. Optional, only if *Protection > Enable auto block* is ticked: *Allow/Block List > Allow List > Create > Single host*, cornil's LAN address (`hostname -I` on cornil), so failed logins during setup cannot get it blocked.
- [ ] A6. Do **not** enable *Terminal & SNMP > SSH* yet. It is only needed for the fallback in section C, path B.

### B. [Cornil] Check the network, create the key, remember the NAS's identity
- [ ] B1. Reachability (run the Variables block first):

      getent hosts "$NAS"          # must print the NAS address
      nc -vz "$NAS" 22             # expect: succeeded / open

  "Connection refused" = nothing listens on 22: recheck A1 (and the port). "Timed out" = firewall (A5).
- [ ] B2. Folder and key. The passphrase is empty on purpose: the backup runs unattended. The key can only write into one share as a non-admin user, and the folder is private to the service user.

      umask 077
      mkdir -p "$KEYDIR" && cd "$KEYDIR"
      [ -e id_ed25519 ] && echo "key already exists: keep it" || ssh-keygen -t ed25519 -N "" -C "restic-cornil" -f id_ed25519
      chmod 700 "$KEYDIR"; chmod 600 id_ed25519; chmod 644 id_ed25519.pub
      ls -l "$KEYDIR"

  If you made the key on the MacBook instead, copy **both** files into `$KEYDIR` on cornil with `scp` and run the three `chmod` lines. Simpler: let cornil make its own and ignore the Mac's.
- [ ] B3. Record the NAS host key so the container can verify it (it cannot ask you "yes/no" in a nightly job):

      cd "$KEYDIR"
      ssh-keyscan "$NAS" > known_hosts
      ssh-keygen -lf known_hosts   # shows fingerprints; (optional) compare with the NAS later
      chmod 600 known_hosts

  If the NAS is on a port other than 22 add `-p <port>` to `ssh-keyscan`. The name must be exactly `barnes.fritz.box`, the same spelling as in the repository address.
- [ ] B4. The ssh settings the container will use (paths are the ones **inside** the container, where this folder is mounted at `/root/.ssh`):

      cd "$KEYDIR"
      printf '%s\n' \
        'Host barnes.fritz.box' \
        '    IdentityFile /root/.ssh/id_ed25519' \
        '    IdentitiesOnly yes' \
        '    UserKnownHostsFile /root/.ssh/known_hosts' \
        '    StrictHostKeyChecking yes' \
        '    BatchMode yes' \
        '    ServerAliveInterval 60' > config
      chmod 600 config
      cat config

  Add a `Port <n>` line if the port is not 22.

### C. Install the public key on the NAS (pick path A; path B only if A fails)

**Path A. [Cornil to Barnes] through SFTP with the password (no admin, no SSH needed).** You own your home folder, so you can create `.ssh` and change modes through SFTP.

      cd "$KEYDIR"
      sftp "$NAS_USER@$NAS"        # asks for the NAS user's password

Then, one line at a time at the `sftp>` prompt:

      pwd                                   # expect /  (a virtual root)
      ls /                                  # expect /home (your home folder) and /<your share>
      cd /home
      mkdir .ssh                            # "Failure" if it exists is fine
      put id_ed25519.pub .ssh/authorized_keys
      chmod 700 .ssh
      chmod 600 .ssh/authorized_keys
      chmod 755 /home                       # may be refused (Permission denied): then see C1b
      ls -la                                # home: expect drwxr-xr-x
      ls -la .ssh                           # expect -rw------- authorized_keys
      bye

- [ ] C1. Path A done and the listing looks as above.

- [ ] C1b. **Found on the first real run (2026-11-09): "Authentication refused: bad ACL permission for file .../authorized_keys".** Synology's sshd also checks the file's ACL (the `+` after the mode in `ls -l`), and the SFTP `chmod` does not remove it. The key is then ignored although the modes look right. Fix, in an admin SSH session on the NAS (C2; the same trace came from `sudo /bin/sshd -p 2222 -d`):

      H=/volume1/homes/<NAS_USER value>
      sudo synoacltool -del "$H/.ssh/authorized_keys"
      sudo chmod 600 "$H/.ssh/authorized_keys"
      sudo ls -ld "$H/.ssh/authorized_keys"     # expect -rw------- with no "+"

  If it is still refused, do the same for `$H/.ssh` (`chmod 700`) and then `$H` (`chmod 755`). With this fix the key login worked on DSM 7.2.2 (DS218).

**Path B (fallback). [Barnes] as an administrator over SSH.** Use it if `chmod` is refused in path A ("Couldn't setstat").
- [ ] C2. [MacBook, DSM page] *Control Panel > Terminal & SNMP > Enable SSH service* (note the port). Switch it off again at the end of section D if you do not need it.
- [ ] C3. [Cornil] show the one-line public key: `cat "$KEYDIR/id_ed25519.pub"` and copy the whole line.
- [ ] C4. [MacBook or Cornil] log in as the **admin** user: `ssh <admin-user>@barnes.fritz.box`, then:

      H=/volume1/homes/<NAS_USER value>
      sudo mkdir -p "$H/.ssh"
      echo '<paste the single line here, keep the quotes>' | sudo tee -a "$H/.ssh/authorized_keys" >/dev/null
      sudo chown -R <NAS_USER value>:users "$H/.ssh"
      sudo chmod 755 "$H"
      sudo chmod 700 "$H/.ssh"
      sudo chmod 600 "$H/.ssh/authorized_keys"
      ls -ld "$H" "$H/.ssh" "$H/.ssh/authorized_keys"

  The `chown` matters: files made with `sudo` belong to root, and the key file must belong to the user (or root with strict modes). Do **not** upload the key with File Station as the admin: it would be owned by the admin and be ignored. `sshd_config` needs no change on DSM 7 (the community guides say so); only run `sudo systemctl reload sshd` if you edited it.

### D. [Cornil] Prove key login works, exactly without a password

      cd "$KEYDIR"
      printf 'pwd\nls /\n' | sftp -b - -i id_ed25519 \
        -o IdentitiesOnly=yes -o PasswordAuthentication=no \
        -o UserKnownHostsFile="$KEYDIR/known_hosts" -o StrictHostKeyChecking=yes \
        "$NAS_USER@$NAS"

- [ ] D1. Expect the listing with **no password prompt**. If it says `Permission denied (publickey,password)`:
  1. Re-run with `-vvv` in front of `-b`: look for `Offering public key` then `Authentications that can continue`.
  2. Recheck modes (home 755, `.ssh` 700, file 600, all owned by the NAS user). Repair after any DSM update: modes can be reset by updates.
  3. The `authorized_keys` content must be **one single line** starting `ssh-ed25519`.
  4. Server-side trace (needs admin SSH): `sudo /bin/sshd -p 2222 -d`, then from cornil add `-P 2222` to `sftp` and read the NAS output (this trick is from the 007revad guide). Stop it with Ctrl-C afterwards.
- [ ] D2. (Optional) Turn SSH back off (A6) if you enabled it for path B.

### E. [Cornil] Test the way the real job will run (container, same flags as the unit)
- [ ] E1. The container image must contain an ssh client:

      podman run --rm --entrypoint ssh docker.io/restic/restic:0.19.1 -V

- [ ] E2. [MacBook, in the repo folder] create the restic repository password as a Podman secret on cornil, typed at the hidden prompt (CLAUDE.md rule: never in chat). **Store a copy outside the server (password manager and paper).** Losing it makes the offsite copy unreadable.

      make restic-secret NAME=restic-repo-password

- [ ] E3. [Cornil] create the repository (absolute path: `/<share>/restic`):

      podman run --rm --read-only --security-opt=no-new-privileges --cap-drop=all \
        --secret restic-repo-password,type=mount \
        -e RESTIC_PASSWORD_FILE=/run/secrets/restic-repo-password \
        -e RESTIC_CACHE_DIR=/tmp/cache --tmpfs /tmp \
        -v "$KEYDIR:/root/.ssh:ro" \
        docker.io/restic/restic:0.19.1 -r "sftp:$NAS_USER@$NAS:/$NAS_SHARE/restic" init

  Expect `created restic repository ... at sftp:...`. Then the same command with `snapshots` (expect "no snapshots") and `check` instead of `init`.
  - `mkdirAll ... unable to create directories` = the path was not absolute.
  - `Host key verification failed` = `known_hosts` missing or the host name differs.
  - Name does not resolve inside the container = tell me; the fix is a DNS option in the unit (a repo change for a later session).
- [ ] E4. [Barnes, DSM page] check in File Station that `restic/` appeared in your share, and that the share still has the Recycle Bin off.

### F. [MacBook] Wire it into the repo (done 2026-11-09)
- [ ] F1. Find the absolute key folder on cornil: `echo "$HOME/cornil-platform/restic-ssh"` and which backup folders exist: `ls -d /u01/data/backups /u01/data/parts-db/backups /u01/data/tax-healthcare-tool/backups`. A missing folder makes the backup fail (see `docs/offsite-backup.md`), so list only existing ones.
- [ ] F2. Edit `local/vars.yml` (git-ignored; fake pattern in `local/vars.example.yml`): `restic_repository` (`sftp:<user>@barnes.fritz.box:/<share>/restic`), `restic_ssh_dir` (the absolute path from F1) and, if needed, `restic_backup_paths`.
- [ ] F3. `make restic-deploy`. It installs the service and timer and sends nothing.

### G. [Cornil] First backup, proof of restore, then switch the timer on (Phase U4 acceptance)
- [ ] G1. `systemctl --user start restic-backup.service`, then `journalctl --user -u restic-backup.service -n 60 --no-pager`.
- [ ] G2. Snapshots: the E3 command with `snapshots`; then with `check`.
- [x] G3. Restore into a scratch folder (the real proof). **Done 2026-11-13** with the tested commands now in `docs/offsite-backup.md` "Restoring" (`--read-only` could stay: restic needed no extra temp space): snapshot `e668bb49`, 55 files and folders, identical to the live ones (`diff -rq`). The drill on a fetched dump is `make pg-restore-drill FROM=scratch`.
- [x] G4. `systemctl --user enable --now restic-backup.timer` and `systemctl --user list-timers | grep restic`. Done 2026-11-09. Since 2026-11-13 a slot with the NAS off is skipped, not failed (`restic_reachable_check`).
- [x] G5. Recorded 2026-11-13 in `docs/recovery.md` 7.8 and ADR 0007 ("Phase U4 close-out"). No secrets.

## What the real run showed (2026-11-09 to 2026-11-13)
- B1: port 22 open from cornil with the SFTP service on; no firewall change needed.
- C: over SFTP the home folder is `/home`, not `/homes/<user>`. `chmod 755 /home` is refused and the listing keeps showing `rwxrwxrwx`, although the modes of `.ssh` and the key file did change (seen as admin: `drwx--x--x+`).
- C1b: key login failed with "bad ACL permission for file .../authorized_keys" until the ACL was removed with `synoacltool -del` and the file set to 600. Found with the debug sshd (`sudo /bin/sshd -p 2222 -d`; the client then needs `-P 2222 -o HostKeyAlias=barnes.fritz.box`). Only the file needed the fix, not the folders.
- E: the restic image has an ssh client; name resolution works inside the container; `init` and `check` passed. Set `KEYDIR` in every new terminal: an empty variable gives "host directory cannot be empty".
- F: `restic_backup_paths` had to be cut down to the two existing folders.
- G1, G2, G4: first backup 21.7 MiB; timer enabled with `restic_calendar: "*-*-* 11,14,17:00:00"` because the NAS is off at night. 9 of 10 runs succeeded up to 2026-11-13; one run failed when the NAS closed the connection and the next one succeeded.
- Each line of output carries a harmless ssh warning about post-quantum key exchange (older OpenSSH on the NAS).

## Known limits of this setup
- The NAS is **in the same home** as cornil. It protects against a dead disk and a mistake, **not** against fire, theft or a power surge. The owner accepted this risk for now; revisit with a second copy later (option B/C/D in `docs/offsite-backup.md`).
- The DS218 is a modest CPU; the first backup and each `forget --prune` may take a while. The unit allows 6 h.
- Keep DSM updated, but recheck the home-folder modes (C) after a major update.

## Sources and confidence
Checked online, 2026-11-09:
- Synology DSM help, SFTP service (port 22 default): <https://www.synology.com/en-uk/knowledgebase/DSM/help/DSM/AdminCenter/file_ftp_sftp>
- Synology tutorial, key pairs for admin/root over SSH: <https://kb.synology.com/en-uk/DSM/tutorial/How_to_log_in_to_DSM_with_key_pairs_as_admin_or_root_permission_via_SSH_on_computers>
- Community guide for DSM 7 (home 755, `.ssh`, `authorized_keys`, `systemctl reload sshd`, debug sshd): <https://github.com/007revad/Synology_SSH_key_setup>
- synoforum DSM 7 thread (log line "bad ownership or modes for directory", fix by tightening home/.ssh/authorized_keys modes): <https://www.synoforum.com/threads/anyone-get-passwordless-key-based-ssh-access-to-work-in-dsm-7.5409/>
- Server Fault answer (non-admin users: SFTP works, key auth succeeds, interactive shell refused, "FTP" app permission covers SFTP): <https://kiwix.lema.org/serverfault.com_en_all_2023-11/a/1001304>
- restic: SFTP backend and "absolute path on Synology" (FAQ): <https://restic.readthedocs.io/en/v0.16.4/030_preparing_a_new_repo.html>, and a 2026 write-up of restic to a DSM 7 NAS over SFTP: <https://link2xt.codeberg.page/blog/2026-01-19-restic-backups.html>
- Other: SFTP enabling walk-through for DSM 7: <https://mariushosting.com/synology-how-to-set-up-ftp-on-dsm-7/>

Not verified, because there is no DS218 here and Synology's DSM help pages for user/terminal settings could not be fetched: (1) the exact menu labels in A2 and A4; (2) that `chmod` of the home folder through SFTP is accepted on 7.2.2 (path B is the fallback); (3) the cause of your earlier "connection refused" on `ssh`: B1 will show it; (4) the forum evidence for non-admin key login is from older DSM versions, so D is the real test.
