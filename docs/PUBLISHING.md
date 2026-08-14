# Getting this onto GitHub

This repository is **completely separate** from any other project you have. It has its
own folder, its own `.git`, its own history, and its own remote. Nothing below touches
another repository, and none of it can: git only ever affects the repository whose
folder you are standing in.

## The one rule that keeps them separate

Every git command applies to the repository containing your **current directory**. So
the only way to affect the wrong repo is to run a command while standing in it. Check
before you type:

```powershell
git rev-parse --show-toplevel   # which repository am I in?
git remote -v                   # where would a push go?
```

If the first prints your PTR tool folder and the second prints `wow-ptr-setup-tool`, no
command you run can reach another project.

The repository is at <https://github.com/Klaytee22/wow-ptr-setup-tool>.

## Step 1 — get the code onto your machine

You have it as a **git bundle** — a single file holding the whole repository, commits
and all. Clone from it exactly as you would from a server:

```powershell
cd ~\source            # or wherever you keep projects — anywhere except inside another repo
git clone .\wow-ptr-ui-setup.bundle wow-ptr-setup-tool
cd wow-ptr-setup-tool
git log --oneline      # you should see the commit history
```

> Do not unpack it inside another repository's folder. A repo inside a repo is legal but
> confusing, and it is the one way these could get tangled.

The bundle is now redundant — the clone is a full repository. Git will have set the
bundle as `origin`; step 3 replaces that.

## Step 2 — the empty repository on GitHub

Already done: `Klaytee22/wow-ptr-setup-tool`.

If you ever need another one: <https://github.com/new>, and **do not** tick "Add a
README", "Add .gitignore" or "Choose a license" — the repo must be empty, or the first
push is rejected for having unrelated histories.

## Step 3 — point this repo at it and push

```powershell
cd ~\source\wow-ptr-setup-tool

git remote -v                    # currently points at the bundle
git remote set-url origin https://github.com/Klaytee22/wow-ptr-setup-tool.git
git remote -v                    # confirm it now points at GitHub

git push -u origin main
```

If `git remote -v` printed nothing at all, add it instead of setting it:

```powershell
git remote add origin https://github.com/Klaytee22/wow-ptr-setup-tool.git
git push -u origin main
```

That is it. GitHub Actions will pick up `.github/workflows/ci.yml` and run the test
suite on Windows PowerShell 5.1, PowerShell 7 (Windows and Linux), and PSScriptAnalyzer.

## Step 4 — day-to-day

```powershell
cd ~\source\wow-ptr-setup-tool    # always start here
git status                       # what changed
git add -A
git commit -m "Fix the thing"
git push
```

## Why your other project is safe

| Worry | Why it cannot happen |
|---|---|
| "Will this push into my other repo?" | `git push` sends to the `origin` of the repo you are standing in. Different folder, different `.git`, different remote. |
| "Will its history get mixed in?" | Histories only merge if you explicitly fetch one into the other. Nothing here does. |
| "Will my other repo's CI run this?" | Actions workflows only run for the repository they live in. |
| "Could I overwrite the other repo by mistake?" | Only by setting this repo's `origin` to that repo's URL. Step 3 sets it to `wow-ptr-setup-tool` — read the URL back before pushing. |
| "Do these share settings?" | No. Git config is per-repository, apart from your global name/email. |

The one genuine footgun is copying the files *into* another repository's folder instead
of cloning them next to it. Keep them as sibling folders:

```
~\source\
  roblox-incremental-game-engine\   ← untouched
  wow-ptr-setup-tool\               ← this
```

## If the push is rejected

| Message | Cause | Fix |
|---|---|---|
| `Updates were rejected because the remote contains work that you do not have` | The GitHub repo was created with a README/license | Either delete and recreate it empty, or `git pull --rebase origin main` then push |
| `remote: Repository not found` | Wrong URL, or no access | Re-check `git remote -v`; for a private repo, make sure you are signed in |
| `error: src refspec main does not match any` | Your branch is not called `main` | `git branch --show-current`, then push that name |
| A browser login prompt | GitHub no longer accepts passwords on the command line | Sign in with [GitHub CLI](https://cli.github.com) (`gh auth login`) or use a personal access token as the password |

## Sharing it with your guild

### Cut a release

A release gives people one stable link instead of a branch name, and tells you which
version someone is on when they report something.

```powershell
git tag -a v1.0.0 -m "First release"
git push origin v1.0.0
```

Then on GitHub: **Releases → Draft a new release → choose the `v1.0.0` tag → Publish**.
GitHub attaches *Source code (zip)* on its own, so there is nothing to build or upload.
The link to hand out is:

<https://github.com/Klaytee22/wow-ptr-setup-tool/releases/latest>

That URL always points at the newest release, so it stays correct after the next one.

### The one thing that will generate messages

Windows marks every file that came off the internet. An extracted `.cmd` carrying that
mark shows *"Windows protected your PC"* instead of running, and people read that as a
virus warning rather than as a shrug.

Tell them: **right-click the zip → Properties → tick Unblock → OK, then extract.** One
tick on the zip clears every file inside it. Doing it after extracting means doing it
one file at a time.

### A message you can paste

```
WoW PTR UI Setup — copies your live addons, addon profiles, keybinds, macros and
UI layout onto the PTR client, so you are not rebuilding your interface every patch.

Download: https://github.com/Klaytee22/wow-ptr-setup-tool/releases/latest
  → under Assets, "Source code (zip)"

1. Right-click the zip → Properties → tick "Unblock" → OK.  (Windows blocks
   downloaded scripts otherwise and shows a scary-looking box.)
2. Extract it to Documents or Desktop.
3. Double-click Try-It-Safely.cmd first — it builds a fake game folder and opens
   the tool on that, so you can click around without it touching your real install.
4. When you are happy, double-click Start-PtrUiSetup.cmd for the real thing.

Windows only. Nothing to install — it uses the PowerShell that ships with Windows.

Quit WoW first (both clients), and copy your character to the PTR before you run it.
Press "Preview changes" before "Apply" — preview writes nothing and shows you the
exact file list. Every step that writes anything backs it up first, and there is a
Restore dropdown that undoes any step.

It only ever writes inside the PTR folder. Your live client is read and never
written to.
```

### If someone reports a problem

Ask for the **Results box** at the bottom of the window — errors land there with a line
number, and that is usually enough to place the fault. `Run-Tests.cmd` on their machine
is the next thing: it needs no game folder and confirms whether the problem is their
install or the tool.

## The older notes

## Releasing it to other players

If you want people to download it without using git:

1. Push as above.
2. On GitHub: **Releases → Draft a new release**, tag `v0.3.0`, publish.
3. GitHub attaches a source zip automatically. Anyone can download it, extract, and
   double-click `Start-PtrUiSetup.cmd` — the tool needs nothing installed.

Tell them to keep the folder structure intact: `Start-PtrUiSetup.cmd` looks for
`PtrUiSetup.ps1`, `ui\` and `Modules\` next to itself.
