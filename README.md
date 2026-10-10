# Spaces Computer

Plug-and-play runner for the Spaces virtual computer environment.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/Jaseunda/spaces-computer/main/run.sh | bash
```
Or clone and run:
```bash
./run.sh
```

## spaces CLI

`run.sh` installs; `cli/spaces` tells you what is actually applied. It reads the
running container rather than any config file, because those have disagreed in
every confusing bug this project has had.

```bash
curl -fsSL https://spaces.notapublicfigureanymore.com/install/cli.sh -o /usr/local/bin/spaces
chmod +x /usr/local/bin/spaces
```

Or run it once without installing anything:

```bash
curl -fsSL https://spaces.notapublicfigureanymore.com/install/cli.sh | bash -s -- doctor
```

| command | what it answers |
| --- | --- |
| `spaces doctor` | every moving part: docker, container, control identity, screen, key, image, both tunnels - each failure prints the repair |
| `spaces status` | the digests that are really applied: running container, local image, published image, key fingerprint |
| `spaces update` | pull the published image, and recreate the computer only if it changed (your key and files are kept) |
| `spaces link` | the live control tunnel, whether it answers as control, and the key it accepts |

The key lives at `~/.spaces/computer-home/.spaces/token` and is reused across
runs, so re-running the launcher never invalidates a connect link you already
pasted. Delete that file to rotate it on purpose.

## Configuration

Default ports and credentials:
- Control API: `http://127.0.0.1:7070`
- Web Screen: `http://127.0.0.1:6080/embed.html`
- Token: `spaces-secret-token`
