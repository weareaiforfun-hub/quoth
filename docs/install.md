# Install Quoth

This guide takes you from download to your first dictation, step by step. You don't need Terminal or any technical knowledge. It takes about 10 minutes, plus waiting while the AI models download.

## Before you start

Quoth needs:

- **A Mac with Apple Silicon** (M1, M2, M3, M4 or later). To check: click the Apple menu  → **About This Mac**. Next to **Chip** it should say "Apple M…". If it says "Intel", Quoth won't run on this Mac.
- **macOS 14 (Sonoma) or later.** The same window shows your macOS version.
- **3 to 10 GB of free disk space** for the AI models, depending on your Mac's memory.

## Why there's one extra step

The first time you open Quoth, macOS blocks it and you have to allow it once in System Settings. This is expected, and here's why:

> Apple charges developers a yearly fee (€99 every year) to register their apps, and only then does macOS open an app without asking. Quoth is free and I don't earn anything from it, so to avoid paying Apple that fee every year, I found a different way to publish it for free. The only cost is this one extra click for you, the first time you open it.

Your safety isn't affected:

- **Quoth is open source:** anyone can read all of its code [on GitHub](https://github.com/weareaiforfun-hub/quoth).
- **Every release is signed with the same certificate,** so macOS can tell it hasn't been changed since it was built.
- **Updates are signed too.** Quoth only installs an update that carries its own signature, and updates open without the extra step.
- **Everything stays on your Mac.** Quoth works offline and sends nothing anywhere unless you choose a cloud service yourself ([Privacy](privacy.md)).

Only allow apps this way when you trust where they came from. For Quoth, download only from the [official releases page](https://github.com/weareaiforfun-hub/quoth/releases/latest).

## Step 1: Download

Click **[Download Quoth for Mac](https://github.com/weareaiforfun-hub/quoth/releases/latest/download/Quoth.dmg)**. A file called **Quoth.dmg** (about 15 MB) lands in your **Downloads** folder.

## Step 2: Put Quoth in Applications

1. Open your **Downloads** folder and double-click **Quoth.dmg**.
2. A window opens with the Quoth icon on the left and an **Applications** folder on the right.
3. **Drag the Quoth icon onto the Applications folder** and wait a second while it copies.
4. Close that window. In the Finder sidebar, under **Locations**, click the **⏏** eject button next to **Quoth**.
5. You can now move **Quoth.dmg** to the Bin. You don't need it any more.

## Step 3: Open Quoth the first time (the extra step)

1. Open your **Applications** folder (in Finder, or press **⌘⇧A**) and double-click **Quoth**.
2. macOS shows a message: *"Quoth" Not Opened. Apple could not verify "Quoth" is free of malware…*. Click **Done**. (Don't click **Move to Bin**.) On macOS 14 the message is worded a little differently and the button says **OK**.
3. Open **System Settings** ( → System Settings…) and click **Privacy & Security** in the sidebar.
4. Scroll all the way down to the **Security** section. You'll see *"Quoth" was blocked to protect your Mac*. Click **Open Anyway** next to it.
5. Enter your Mac password or use Touch ID.
6. macOS asks once more. Click **Open Anyway**.

Quoth opens. You only do this once. From now on Quoth opens normally, and so do its updates.

**Can't find Open Anyway?** The button only appears for about an hour after step 2. Go back to Applications, double-click Quoth again, click **Done**, and then look in Privacy & Security again.

## Step 4: Download the AI models

Quoth opens on its **Setup** page. Quoth uses two AI models, which it downloads once:

- one turns your voice into text;
- the other tidies the text up: it removes the "um"s, applies your corrections, adds punctuation.

1. Under **AI models**, Quoth has already chosen the right size for your Mac and marked it **Recommended for this Mac**:

   | Your Mac's memory | Models | Download |
   | --- | --- | --- |
   | 8 GB | Lite | 3 GB |
   | 16 GB | Standard | 5.3 GB |
   | 32 GB or more | Best | 9.6 GB |

2. Click **Download**.

The download runs in the background, so carry on with step 5 while it works. You can close the window or even restart your Mac: the download picks up where it left off.

## Step 5: Give Quoth three permissions

macOS asks you to allow these yourself; no app can switch them on alone. On the Setup page, under **Permissions**, click **Grant…** next to each one. A green tick appears when it's done; you don't need to restart Quoth.

| Permission | Why Quoth needs it | What to do |
| --- | --- | --- |
| **Microphone** | To hear you while you hold the key. | Click **Allow** in the pop-up. |
| **Accessibility** | To type the text into the app you're using. | System Settings opens. Switch on **Quoth** in the list and enter your password. |
| **Input Monitoring** | To notice when you hold the dictation key. | System Settings opens. Switch on **Quoth** and enter your password. If macOS offers **Quit & Reopen**, either choice is fine. |
| Screen & System Audio Recording *(optional)* | Only for meeting notes, to hear the other people on a call. No video is kept. | Skip it unless you want meeting notes. |

Quoth never reads what you type. It only listens for the dictation key, and it won't type into password fields.

**One more setting:** Quoth's dictation key is **Fn** (🌐), the bottom-left key on most Mac keyboards. So that macOS doesn't open the emoji picker when you hold it, open **System Settings → Keyboard**, find **Press 🌐 key to**, and choose **Do Nothing**.

## Step 6: Your first dictation

Wait until the model download has finished (the Setup page shows **Models ready**). Then:

1. Click into any text field: a new note in Notes, an email, a chat message.
2. **Hold Fn** and say: *"Um, so let's meet at two, actually three, on Thursday."*
3. **Let go.** A second or so later, Quoth types: *So let's meet at 3 on Thursday.*

While you speak, a small pill at the bottom of the screen shows a waveform. While Quoth thinks, it shows dots. You're all set.

A few things to try next:

- **Double-tap Fn** to dictate hands-free. Tap once more to stop.
- Say *"one… two… three…"* to get a numbered list.
- Select some text, hold **Fn + Control**, and say *"make this more formal"*.

The [User guide](user-guide.md) explains everything else Quoth can do.

## Updates

The second time you open Quoth, it asks whether it may check for updates automatically. Choose **Check Automatically**: Quoth then looks for a new version once a day and asks before installing it. Updates open straight away, without the extra step from step 3. You can also check yourself: click the Quoth icon in the menu bar and choose **Check for Updates…**.

## If something doesn't work

| Problem | What to do |
| --- | --- |
| "Quoth.dmg" opens an empty window | Eject the **Quoth** disk in the Finder sidebar and download Quoth.dmg again. |
| There's no **Open Anyway** button | Open Quoth from Applications again, click **Done**, then look in Privacy & Security again (step 3). |
| Nothing happens when I hold Fn | Check that all three permissions on the Setup page have a green tick, and that the models have finished downloading. |
| The emoji picker opens | Set System Settings → Keyboard → **Press 🌐 key to** → **Do Nothing**. |
| My keyboard has no Fn key | Click the Quoth icon in the menu bar → **Open Quoth…** → **Settings**, and choose another key, such as **Right Option**. |
| The text appears but isn't tidied up | The second model is still downloading or loading. Wait a minute and try again. |
| The text appears in the wrong place | Quoth types where your cursor was when you **started** speaking. Click into the field first. |
| Something else | Click the Quoth icon in the menu bar → **Open Quoth…** → **Settings** → **Help** → **Report a Problem…**. This opens a form on GitHub and copies technical details for you to paste in. They never include what you dictated. |

## Uninstall

1. Click the Quoth icon in the menu bar and choose **Quit Quoth**.
2. Drag **Quoth** from Applications to the Bin.
3. To also delete your models, history and settings: in Finder press **⌘⇧G**, type `~/Library/Application Support/Quoth`, press Return, and move that folder to the Bin.
