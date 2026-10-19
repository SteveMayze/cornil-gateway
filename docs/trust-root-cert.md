# Trusting the gateway's certificate on your devices

## What this is and why
`https://cornil.fritz.box` is a private address, so no public authority will vouch for it. Caddy therefore acts as its own small **certificate authority** (CA) and signs the site's certificate itself. A device only trusts that signature if you hand it the CA's **public root certificate** once. The file is called `cornil-root.crt`. It is safe to share: it is the public half only. (The private half never leaves the server, and nothing here ever asks for it.)

Until a device has the file installed, its browser shows "Your connection is not private". After it is installed, the padlock is normal.

## Step 1: get the file onto your Mac
```
make root-cert
```
What this does: copies only the public `root.crt` from the server to `local/cornil-root.crt` and prints its **fingerprint** (a short code that identifies this exact certificate).
Normal output: `Saved: local/cornil-root.crt`, a `subject=CN=Caddy Local Authority ...` line, an end date, and a `sha256 Fingerprint=...` line.
If it fails: "Missing"/"No such file" means Caddy has not started yet (`make status`, then `make deploy`). Any message about a private key means stop and tell me.

**Write down or screenshot the fingerprint.** On each device you can compare it with the one shown in the certificate details, so you know you installed the right file.

Send the file to each device (AirDrop, email to yourself, or a USB stick). It is not secret.

## A warning about the January 2026 certificate
Your devices may already trust an older certificate from the ESP32 experiment. It has a very similar name ("Caddy Local Authority - 2026 ECC Root") but a **different fingerprint**. The new Caddy uses a new CA, so the new file must be installed even if you see that name. Once the new one works, remove the old one (look it up by fingerprint) so you do not have two lookalikes.

## macOS (MacBook Pro, iMac)
1. Double-click `cornil-root.crt`. Keychain Access opens. Choose the **login** keychain (or **System** to cover all users; this asks for your Mac password).
2. In Keychain Access, find "Caddy Local Authority", double-click it, open **Trust**, set "When using this certificate" to **Always Trust**, close the window and enter your password.
3. Restart the browser. Safari and Chrome use the keychain. **Firefox** has its own list: Settings, Privacy & Security, Certificates, View Certificates, Authorities, Import; or set `security.enterprise_roots.enabled` to `true` in `about:config`.
Check: open `https://cornil.fritz.box/` and click the padlock; it should say the connection is secure.

## iPhone and iPad (iOS / iPadOS)
Two steps; the second is easy to miss.
1. Open the file (from AirDrop or Mail or Files). It says "Profile Downloaded". Open **Settings**, tap **Profile Downloaded** at the top, tap **Install**, enter your passcode, tap **Install** again.
2. **Settings > General > About > Certificate Trust Settings**, switch **on** the toggle for "Caddy Local Authority".
Check: open `https://cornil.fritz.box/` in Safari.

## Android
1. Copy the file to the phone. **Settings > Security (or Security & privacy) > More security settings > Encryption & credentials > Install a certificate > CA certificate**, accept the warning, pick the file. (Menu names differ a little by maker; searching Settings for "CA certificate" finds it.)
2. Chrome uses it straight away. Firefox for Android needs its own setting.

## Windows
1. Double-click `cornil-root.crt`, choose **Install Certificate**, **Local Machine** (needs administrator approval), **Place all certificates in the following store**, **Browse**, **Trusted Root Certification Authorities**, **Finish**.
   Or, in an administrator PowerShell: `certutil -addstore -f ROOT cornil-root.crt`
2. Restart the browser. Edge and Chrome use it. Firefox: set `security.enterprise_roots.enabled` to `true` in `about:config`.

## Checking it worked
From your Mac, with the file in `local/`: `make smoke` (add `HTTPS_PORT=8443 HTTP_PORT=8080` while the gateway is still on the trial ports). It uses the file directly and does not prove a device trusts it; for that, open the address on the device.

## If the certificate ever has to be replaced
If the server's CA data is lost, a new CA is created and every device needs the new file (this document again, with the old one removed). Keep the data backups from `make backup-caddy-data` for that reason.
