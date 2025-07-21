# CyRepoLoader (macOS)

A native macOS utility to download and mirror Cydia repositories using modern SwiftUI and pure Swift networking.

## ✨ Features

- 🔗 Enter or paste any Cydia repo URL
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

<img width="1012" height="692" alt="Screenshot1" src="https://github.com/user-attachments/assets/a518618b-032c-41ba-8f39-0a4b26e1f18e" />
<img width="1012" height="692" alt="Screenshot2" src="https://github.com/user-attachments/assets/fc776fc0-a3ee-48d3-905c-f72112ff27a4" />
<img width="1012" height="692" alt="Screenshot3" src="https://github.com/user-attachments/assets/8e17ec81-5db1-498d-9008-eac3702c6542" />
<img width="1012" height="692" alt="Screenshot4" src="https://github.com/user-attachments/assets/f7b3e54b-5e97-4282-9b89-e839860a0d0c" />


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
