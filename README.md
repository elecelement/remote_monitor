<img src="Packaging/AppIcon.png" width="64" height="64" alt="">

# GPU Workbench

English · [简体中文](README.zh-CN.md)

GPU Workbench is a macOS app for checking NVIDIA GPU usage on a Linux server and opening a ready-to-use tmux workspace over SSH. A saved shortcut combines a session name, a Conda environment, and a working directory.

## Build and open

On a Mac with macOS 14 or later, install the Command Line Tools and Swift 6.1 or a compatible toolchain. Run these commands from the repository root. The first build downloads the dependencies pinned in `Package.resolved`.

```sh
bash Packaging/build-app.sh
open "dist/GPU Workbench.app"
```

The script builds for the current Mac and signs the app locally. At the bottom of the sidebar, select **English** or **简体中文** under the globe icon. You can switch before adding your first server or while a terminal is open. The app starts in Chinese and remembers your choice on this Mac. System-provided controls use the macOS language. Terminal output uses the remote program’s language.

## Connect a server

1. Choose **Add Server**. Enter a display name, host, and SSH username, then select your private key on the Mac. Leave the port blank for standard SSH. Custom ports and the optional Conda installation path are under the extra connection options.
2. Fetch the SSH host fingerprint. Compare it with a trusted record or the value provided by the server administrator before saving. For a passphrase-protected key, use **Unlock Key** to load it into the local SSH agent.
3. Open the overview to see utilization, used and total memory, and free memory for each GPU. The foreground app samples about every five seconds. If monitoring is interrupted, the overview keeps the last reading and its timestamp.

The server needs SSH public-key authentication, `/usr/bin/python3` (3.8 or later), Bash, and tmux 3.2 or later. GPU monitoring uses `nvidia-smi`, automatic environment setup uses an existing Conda installation, and code sync uses rsync. If the server is behind a VPN, connect the Mac to that network first.

## Open a workspace

In **Shortcuts**, create an entry with a tmux session name (for example, `research`), a Conda environment (`ml`), and an existing absolute directory on the server (`/work/example-project`). The display name defaults to the session name.

- **Open Workspace** creates the session if needed, with two panes on top and one full-width pane below. Each new Bash shell starts in the chosen directory and prepares the selected environment. If an environment uses custom activation hooks or its setup cannot be verified, the app gives instructions for manual activation.
- Opening a shortcut again resumes its existing session with its current panes and jobs. A same-name conflict offers a different name or a one-time choice to attach after verifying the session is yours. A shared login means that a name alone cannot identify the person running a session.
- **Reconnect** checks the identity of the session that was disconnected. If the original session is gone, the tab keeps its output and offers to create a new session of the same name.
- Select multiple shortcuts to open several tabs. Press `⌘1` to return to the overview. Closing a terminal tab disconnects its local SSH client. Quitting the app closes the remaining connections. Remote tmux jobs can continue running.

## Preview and sync code

1. Choose **Sync Code** beside a shortcut and select the local project folder. Its destination is the shortcut’s existing remote working directory.
2. Choose **Preview** for an rsync dry run. The list shows files that would overwrite a remote copy first, followed by new files. Only regular `.py` and `.sh` files are eligible. The filters skip workbench source trees, app bundles, build output, and common private or manuscript directories.
3. Continue to see the target server and directory and the number of new files and overwrites. Return to the list to reconsider, or confirm the upload. The app checks the list again before transferring the reviewed paths. If the list has changed, run a new preview.

Preview writes no project files on the server. A confirmed upload writes the listed source files and keeps remote-only files. The upload manifest is temporary and stays on the Mac. After a successful sync, the review window keeps the list available for inspection.

## Shared servers and local data

The app uses the system OpenSSH client and pins the verified host key. A changed key blocks the connection. Profiles, shortcuts, and pinned host keys are stored in `~/Library/Application Support/GPUWorkbench/`. Private keys stay in their original locations.

GPU queries and session management send fixed operations over SSH. The app installs no remote agent or startup script. Conda and working-directory changes apply to the newly created pane processes. Normal SSH audit logs and tmux runtime state, including its socket, can remain on the server. Commands you type in the terminal run with the permissions of your Linux account.

## Tests

```sh
swift test --disable-xctest
python3 -B -m unittest discover -s Tests/Remote -v
```

The Python suite uses disposable local sessions. It finds tmux on `PATH`, or you can set `GWB_TEST_TMUX` to the executable. Set `GWB_TEST_CONDA` to a Conda executable to include the real activation test.

The embedded terminal uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
