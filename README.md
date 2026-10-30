# Halo

An on-device AI assistant for macOS that works on any text, in any app. Highlight something, hold **Right ⌥**, move toward an action, and let go.

<img width="960" height="806" alt="demo" src="https://github.com/user-attachments/assets/fba6633c-c5ec-45d1-b63f-98cceee7e707" />


## Download

**[Download Halo.zip](https://github.com/sarimc123/Halo/releases/latest/download/Halo.zip)**

Unzip it and drag **Halo.app** into your Applications folder.
After turning it on, macOS downloads the model in the background. This can take a few minutes.
## Requirements

- macOS 26 or later
- A Mac with Apple silicon and Apple Intelligence turned on (System Settings → Apple Intelligence & Siri)
- Recomended M2 chip and on. Slow on M1 chip.

Everything runs on Apple's on-device model, so your text never leaves your Mac.

## First launch

Halo isn't signed with a paid Apple Developer certificate, so macOS will block it the first time.

1. Open Halo. When macOS says it can't be opened, click **Done**.
2. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Halo message.
3. Open Halo again and confirm.

Or run this once in Terminal:

If in Aplications:
```bash
xattr -dr com.apple.quarantine /Applications/Halo.app
```

If on Desktop:
```bash
xattr -dr com.apple.quarantine ~/Desktop/Halo.app
```


## Permissions

The setup screen walks you through these:

- **Accessibility** (required): reads highlighted text and listens for the shortcut.
- **Screen Recording** (optional): reads text from part of the screen when nothing is highlighted.

After updating Halo, you may need to turn these off and back on in System Settings.

## How to use

| Action | What it does |
|---|---|
| Explain | Explains the text in plain language |
| Summarize | Condenses it, keeping the key facts |
| Rewrite | Makes it clearer and more natural |
| Fix Grammar | Fixes spelling, grammar and punctuation only |
| Reply | Drafts a reply to a message |
| Custom | Does whatever you type |

- **Hold the shortcut**, point at an action, and release.
- **Click the dot** that appears after you highlight text to open the wheel without the keyboard.
- **Nothing highlighted?** Halo lets you drag over part of the screen and reads the text there.
- **Replace** swaps your highlighted text with the result.

You can change the shortcut, response length, tone, and format in **Settings**.

## License

MIT
