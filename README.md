<p align="center">
  <img width="120" height="120" alt="AppIcon" src="https://github.com/user-attachments/assets/6f25362e-c2cc-4274-9757-663923121dc3" />
</p>

<h1 align="center">CyRepoLoader</h1>

<p align="center">
  A native macOS utility to download and mirror Cydia repositories using modern SwiftUI and pure Swift networking.
</p>

<p align="center">
  <a href="https://github.com/victorlobe/CyRepoLoader/releases/latest">
    <img alt="Download" src="https://img.shields.io/badge/download-latest-blue?logo=apple" />
  </a>
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS-007AFF">
</p>

---


## ✨ Features

- 🔗 Make an archive of every Cydia (or Installer) repo.
- 📜 View real time download progress and logs
- 🧠 Automatically remembers recent repo URLs  
- 🛑 Cancel downloads anytime  
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
- To compile this project on older Xcode Versions than Xcode 26 you maybe have to remove the AppIcon.icon file in the CyRepoLoader Folder.

## 🗒️ To Do

- [ ] Compare Repos with local files
- [ ] Add a remote function for headless servers
- [ ] Support for Installer.app repos

## 🐞 Known Bugs

- App may freeze briefly when parsing very large repos
- Occasional UI lag when displaying large log outputs
- When scrolling down the Log while the tool is running, the log scrolls down by itself.

## 🧠 Behind the Scenes

All mirroring is done natively using Swift and URLSession with custom logic to parse repo metadata and download repository files efficiently.

👨‍💻 Author

Made with ❤️ by Victor Lobe

📄 License

MIT License – Free to use, share, and modify.

---

Yes, ChatGPT helped me with this Readme.
