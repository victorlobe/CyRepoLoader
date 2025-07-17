# Cydia Repo Downloader (SwiftUI)

A native macOS utility to download and mirror Cydia repositories with a modern, clean SwiftUI interface.  
Powered by `wget` under the hood.

## ✨ Features

- 🔗 Enter or paste any Cydia repo URL (`http` or `https`)
- 📁 Choose your download destination folder
- 📜 View real-time download logs in a live console
- ⏸️ Pause, resume, and cancel downloads anytime
- 🧠 Automatically remembers recent URLs
- 🧹 Clears old logs before each download
- 📂 Open the download folder directly after completion
- 📥 Full mirror using `wget` (`--mirror`, `--no-parent`, etc.)
- 🧠 Intelligent error highlighting (404s, network failures, etc.)
- 🧪 Drag-and-drop folder support
- 🌗 Fully native, SwiftUI-based, fast and lightweight

## 🧰 Requirements

- macOS 12.0+
- `wget` installed (via [Homebrew](https://brew.sh): `brew install wget`)

## 📸 Screenshots

> _Coming Soon_

## 🚀 How to Use

1. **Enter a Cydia Repo URL**, e.g.  
   `http://repo.victorlobe.me`

2. **Choose a destination folder** where the mirror will be saved

3. **Click “Start Download”**

4. Sit back and monitor progress in the real-time log

5. When done, click **“Open Folder”** to access the full repo mirror

## 🛑 Notes

- This tool mirrors the full repo structure including `Packages`, `.deb` files, and metadata.
- Errors and missing files will be logged to `wget-errors.log` inside the repo folder.
- Temporary logs are saved as `wget.log` in the destination folder.

## 🧠 Behind the Scenes

Uses the following `wget` options:

```bash
wget --mirror --no-parent --convert-links --restrict-file-names=windows --wait=1 -e robots=off <REPO_URL>
```

👨‍💻 Author

Made with ❤️ by Victor Lobe

📄 License

MIT License – Free to use, share, and modify.

---
Yes, this Readme was created with ChatGPT because i´m too lazy to make a proper one.
