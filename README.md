# Cydia Repo Downloader (SwiftUI)

A native macOS utility to download and mirror Cydia repositories using modern SwiftUI and pure Swift networking.

## ✨ Features

- 🔗 Enter or paste any Cydia repo URL (http or https)  
- 📁 Choose your download destination folder (with drag-and-drop support)  
- 📜 View real time download progress and logs  
- 🛑 Cancel downloads anytime  
- 🧠 Automatically remembers recent repo URLs  
- 📥 Full repo mirror: All .deb files and metadata of the repo are saved.
- 🧠 Error detection and summary display for failed downloads  
- 🌗 Fully native, SwiftUI based, fast and lightweight  

## 🧰 Requirements

- macOS 12.0+  

## 📸 Screenshots

> _Coming Soon_

## 🚀 How to Use

1. **Enter a Cydia Repo URL**, e.g.  
   `http://repo.victorlobe.me`

2. **Choose a destination folder**

3. **Click “Start Download”**

4. Sit back and monitor the progress in the real time.

5. When done, click **“Open Folder”** to access the full repo mirror

## 🛑 Notes

- This tool mirrors the full repo structure including `Packages`, `.deb` files, and metadata.  
- Errors and missing files will be indicated in the app's error summary.  
- Temporary logs and progress are displayed live within the app interface.

## 🧠 Behind the Scenes

All mirroring is done natively using Swift and URLSession with custom logic to parse repo metadata and download repository files efficiently.

👨‍💻 Author

Made with ❤️ by Victor Lobe

📄 License

MIT License – Free to use, share, and modify.

---
