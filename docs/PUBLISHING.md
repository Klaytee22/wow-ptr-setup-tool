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

If the first prints your PTR tool folder and the second prints `wow-ptr-ui-setup`, no
command you run can reach another project.

## Step 1 — get the code onto your machine

You have it as a **git bundle** — a single file holding the whole repository, commits
and all. Clone from it exactly as you would from a server:

```powershell
cd ~\source        # or wherever you keep projects — anywhere except inside another repo
git clone .\wow-ptr-ui-setup.bundle wow-ptr-ui-setup
cd wow-ptr-ui-setup
git log --oneline  # you should see the commit history
```

> Do not unpack it inside another repository's folder. A repo inside a repo is legal but
> confusing, and it is the one way these could get tangled.

The bundle is now redundant — the clone is a full repository. Git will have set the
bundle as `origin`; step 3 replaces that.

## Step 2 — create the empty repository on GitHub

1. Go to <https://github.com/new>.
2. **Owner**: your account. **Name**: `wow-ptr-ui-setup`.
3. **Private** unless you want it public.
4. **Do not** tick "Add a README", "Add .gitignore", or "Choose a license". The repo must
   be empty, or the first push will be rejected for having unrelated histories.
5. Create it. GitHub shows a URL like
   `https://github.com/<you>/wow-ptr-ui-setup.git` — copy it.

## Step 3 — point this repo at it and push

```powershell
cd ~\source\wow-ptr-ui-setup

git remote -v                    # currently points at the bundle
git remote set-url origin https://github.com/<you>/wow-ptr-ui-setup.git
git remote -v                    # confirm it now points at GitHub

git push -u origin main
```

If `git remote -v` printed nothing at all, add it instead of setting it:

```powershell
git remote add origin https://github.com/<you>/wow-ptr-ui-setup.git
git push -u origin main
```

That is it. GitHub Actions will pick up `.github/workflows/ci.yml` and run the test
suite on Windows PowerShell 5.1, PowerShell 7 (Windows and Linux), and PSScriptAnalyzer.

## Step 4 — day-to-day

```powershell
cd ~\source\wow-ptr-ui-setup     # always start here
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
| "Could I overwrite the other repo by mistake?" | Only by setting this repo's `origin` to that repo's URL. Step 3 sets it to `wow-ptr-ui-setup` — read the URL back before pushing. |
| "Do these share settings?" | No. Git config is per-repository, apart from your global name/email. |

The one genuine footgun is copying the files *into* another repository's folder instead
of cloning them next to it. Keep them as sibling folders:

```
~\source\
  the-other-project\        ← untouched
  wow-ptr-ui-setup\         ← this
```

## If the push is rejected

| Message | Cause | Fix |
|---|---|---|
| `Updates were rejected because the remote contains work that you do not have` | The GitHub repo was created with a README/license | Either delete and recreate it empty, or `git pull --rebase origin main` then push |
| `remote: Repository not found` | Wrong URL, or no access | Re-check `git remote -v`; for a private repo, make sure you are signed in |
| `error: src refspec main does not match any` | Your branch is not called `main` | `git branch --show-current`, then push that name |
| A browser login prompt | GitHub no longer accepts passwords on the command line | Sign in with [GitHub CLI](https://cli.github.com) (`gh auth login`) or use a personal access token as the password |

## Releasing it to other players

If you want people to download it without using git:

1. Push as above.
2. On GitHub: **Releases → Draft a new release**, tag `v0.3.0`, publish.
3. GitHub attaches a source zip automatically. Anyone can download it, extract, and
   double-click `Start-PtrUiSetup.cmd` — the tool needs nothing installed.

Tell them to keep the folder structure intact: `Start-PtrUiSetup.cmd` looks for
`PtrUiSetup.ps1`, `ui\` and `Modules\` next to itself.
